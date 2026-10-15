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
    #   (a typo: `ownr`);
    # - :unjoinable_association — the association is there, but no join can
    #   be built through it: a polymorphic belongs_to, a scope that takes the
    #   record, a :through or inverse_of naming an association that does not
    #   exist, a class that cannot be loaded.
    #
    # Everything ActiveRecord joins — has_many / has_one / belongs_to,
    # :through, has_and_belongs_to_many, a scoped association — is followed.
    # A rule whose path is broken matches nothing (PermissionRuleApplier):
    # the join would raise.
    #
    # @example
    #   path = RulePath.follow(Customer, %w[supplier owner])
    #   path.models  # => [Customer, Supplier, User]
    #   RulePath.follow(Customer, %w[ownr]).reason # => :unknown_association
    class RulePath
      # @return [Array<Class>] the rule's model, then the model of each
      #   association on the path; empty when the path is broken
      attr_reader :models
      # @return [String, nil] the segment the path breaks at
      attr_reader :segment
      # @return [Class, nil] the model that segment was looked up in
      attr_reader :owner
      # @return [Symbol, nil] :unknown_association or :unjoinable_association
      attr_reader :reason

      # @param model [Class] the rule's model
      # @param association_chain [Array<String>] the rule's field_accessor_path, split
      # @return [RulePath]
      def self.follow(model, association_chain)
        association_chain.reduce(new([model])) do |path, name|
          path.through(name.to_s)
        end
      end

      def initialize(models, segment = nil, owner = nil, reason = nil)
        @models = models
        @segment = segment
        @owner = owner
        @reason = reason
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
        reflection = owner._reflect_on_association(name)
        return RulePath.new([], name, owner, :unknown_association) unless reflection

        joined = joined_class(reflection)
        joined ? RulePath.new(models + [joined], nil, nil, nil) : RulePath.new([], name, owner, :unjoinable_association)
      end

      private

      # The class a join through the reflection reaches, or nil where
      # ActiveRecord would raise building it. A raise of any kind counts:
      # it would be raised in the holders' queries.
      def joined_class(reflection)
        reflection.check_validity!
        reflection.check_eager_loadable!
        reflection.klass unless reflection.polymorphic?
      rescue StandardError
        nil
      end
    end
  end
end
