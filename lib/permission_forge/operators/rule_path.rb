# frozen_string_literal: true

module PermissionForge
  module Operators
    # A join rule's association path (its field_accessor_path, split on
    # dots), followed from the rule's model the way ActiveRecord follows it
    # when it builds the join: the one walk of a path (the applier, the
    # column lookup, the model's validation and the audit all go through it).
    #
    # ActiveRecord raises for a join it cannot build — when the query runs,
    # so in every find_by / permission_scoped of the rule's holders. Before
    # it joins a name (Associations::JoinDependency#build) it looks the
    # association up by that name and asks the reflection check_validity!
    # and check_eager_loadable!; a polymorphic one raises, and the class of
    # every other one is loaded. A segment that fails any of those is where
    # the path {#broken?}:
    #
    # - :unknown_association — the model has no association of that name
    #   (a typo: `ownr`), or the segment is empty (`parent..owner`; cause
    #   :empty_segment);
    # - :unjoinable_association — the association is there, but no join can
    #   be built through it; {#cause} says why (UNJOINABLE_CAUSES).
    #
    # Everything ActiveRecord joins — has_many / has_one / belongs_to,
    # :through, has_and_belongs_to_many, a scoped association — is followed.
    # A rule whose path is broken matches nothing (PermissionRuleApplier):
    # the join would raise.
    #
    # A model file that raises a ScriptError (SyntaxError, LoadError) while
    # it loads is not a broken path: the error propagates, from the applier
    # too (the query raises; it never answers). An admin-facing caller that
    # only describes the path (RuleProblem.of_path, RuleColumn.for_rule)
    # treats it as "cannot tell".
    #
    # @example
    #   path = RulePath.follow(Customer, %w[supplier owner])
    #   path.models  # => [Customer, Supplier, User]
    #   RulePath.follow(Customer, %w[ownr]).reason # => :unknown_association
    class RulePath
      # Why an association is there but cannot be joined (#cause of an
      # :unjoinable_association path), in the order they are checked:
      #
      # - :invalid_definition — its :through, :source or inverse_of names an
      #   association that is not there (Reflection#check_validity! raises);
      # - :polymorphic — a polymorphic belongs_to: no one class to join;
      # - :record_dependent_scope — its scope, or one along its :through
      #   (the through association's or the source's), takes the record
      #   (`->(record) { … }`): a join has no record to give it;
      # - :class_not_loadable — its class (or one along its :through) cannot
      #   be loaded: no such constant, or its file raised while it loaded.
      UNJOINABLE_CAUSES = %i[invalid_definition polymorphic record_dependent_scope class_not_loadable].freeze

      # @return [Array<Class>] the rule's model, then the model of each
      #   association on the path; empty when the path is broken
      attr_reader :models
      # @return [String, nil] the segment the path breaks at
      attr_reader :segment
      # @return [Class, nil] the model that segment was looked up in
      attr_reader :owner
      # @return [Symbol, nil] :unknown_association or :unjoinable_association
      attr_reader :reason
      # @return [Symbol, nil] :empty_segment for an empty segment, one of
      #   UNJOINABLE_CAUSES for an :unjoinable_association, else nil
      attr_reader :cause

      # @param model [Class] the rule's model
      # @param association_chain [Array<String>] the rule's field_accessor_path, split
      # @return [RulePath]
      def self.follow(model, association_chain)
        association_chain.reduce(new([model])) do |path, name|
          path.through(name.to_s)
        end
      end

      def initialize(models, segment: nil, owner: nil, reason: nil, cause: nil)
        @models = models
        @segment = segment
        @owner = owner
        @reason = reason
        @cause = cause
      end

      def broken?
        !@reason.nil?
      end

      # The path one association further; a broken path stays broken where it broke.
      #
      # @param name [String] the next segment
      # @return [RulePath]
      def through(name)
        return self if broken?

        owner = models.last
        at = { segment: name, owner: owner }
        return RulePath.new([], **at, reason: :unknown_association, cause: :empty_segment) if name.empty?

        reflection = owner._reflect_on_association(name)
        return RulePath.new([], **at, reason: :unknown_association) unless reflection

        cause = RulePath.unjoinable_cause(reflection)
        return RulePath.new([], **at, reason: :unjoinable_association, cause: cause) if cause

        RulePath.new(models + [reflection.klass])
      end

      class << self
        # The relation with the path joined, the way every rule's join is
        # made (the applier's query, RuleColumn.join_names): one association
        # by name, a longer path as the nested Hash ActiveRecord joins.
        #
        # @param relation [ActiveRecord::Relation]
        # @param join_method [Symbol] one of PermissionRuleApplier::JOIN_METHODS — never a rule's own text
        # @param association_chain [Array<String>] the rule's path, split
        # @return [ActiveRecord::Relation]
        def join(relation, join_method, association_chain)
          return relation if association_chain.empty?

          relation.public_send(join_method, join_structure(association_chain))
        end

        # Where ActiveRecord would raise building a join through the
        # reflection, why (UNJOINABLE_CAUSES); nil when it builds one. A raise
        # of any kind counts: it would be raised in the holders' queries.
        # check_validity! and check_eager_loadable! are what JoinDependency
        # asks of the reflection itself; a :through also evaluates the scopes
        # along its chain (record_dependent?).
        #
        # @param reflection [ActiveRecord::Reflection::AbstractReflection]
        # @return [Symbol, nil] one of UNJOINABLE_CAUSES
        def unjoinable_cause(reflection)
          failure(:invalid_definition) { reflection.check_validity! } ||
            (:polymorphic if reflection.polymorphic?) ||
            failure(:record_dependent_scope) { reflection.check_eager_loadable! } ||
            failure(:class_not_loadable) { reflection.klass } ||
            (:record_dependent_scope if record_dependent?(reflection))
        end

        private

        # `supplier` => :supplier; `supplier.owner` => { supplier: :owner }.
        def join_structure(association_chain)
          *outer, last = association_chain.map(&:to_sym)
          outer.reverse.reduce(last) { |inner, name| { name => inner } }
        end

        # nil when the block raises nothing (what it answers is not looked
        # at). When it raises: `cause` for what a definition or a check raises
        # (an ActiveRecordError, ArgumentError or NoMethodError), else
        # :class_not_loadable — a constant that is not there (NameError), or
        # whatever a model file raised as it loaded.
        def failure(cause)
          yield
          nil
        rescue NoMethodError, ArgumentError, ActiveRecord::ActiveRecordError
          cause
        rescue StandardError
          :class_not_loadable
        end

        # Whether a scope along the reflection's join chain takes the record:
        # the reflection's own, the :through association's (and so on along
        # the chain), and the source's of each :through. A chain that cannot
        # be walked counts: the join would raise walking it.
        def record_dependent?(reflection)
          reflection.chain.any? do |link|
            takes_record?(link.scope) || (link.through_reflection? && record_dependent?(link.source_reflection))
          end
        rescue StandardError
          true
        end

        def takes_record?(scope)
          !scope.nil? && !scope.arity.zero?
        end
      end
    end
  end
end
