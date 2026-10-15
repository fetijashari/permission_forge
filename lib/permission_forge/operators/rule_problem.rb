# frozen_string_literal: true

module PermissionForge
  module Operators
    # The English of RuleProblem#validation_message, by RuleProblem#key
    # (translated under permission_forge.validations.permission_set_rule).
    RULE_PROBLEM_MESSAGES = {
      unknown_association: 'names %<association>s, which is not an association of %<model>s',
      empty_association: 'has an empty association name (two dots in a row, or a dot at the start)',
      unjoinable_association: 'names %<association>s, an association of %<model>s that a rule cannot join',
      unjoinable_invalid_definition: 'names %<association>s, an association of %<model>s whose :through, :source ' \
                                     'or inverse_of names an association that is not there',
      unjoinable_polymorphic: 'names %<association>s, a polymorphic association of %<model>s: a rule cannot join it',
      unjoinable_record_dependent_scope: 'names %<association>s, an association of %<model>s whose scope (or one ' \
                                         'along its :through) takes the record: a rule cannot join it',
      unjoinable_class_not_loadable: 'names %<association>s, an association of %<model>s whose class cannot be loaded',
      unknown_column: 'is not a column of %<model>s'
    }.freeze

    # Why a saved rule matches nothing because it names something that is not
    # there: the one definition of a "broken" rule, which the audit
    # (`missing_rule_columns`), the admin's Home ("Needs attention") and the
    # admin's rule sentences all ask.
    #
    # - :unknown_association / :unjoinable_association — a join rule whose
    #   association path cannot be followed ({RulePath#broken?}); `name` is
    #   the segment, `model` the model it was looked up in, `cause` why
    #   ({RulePath#cause}: :empty_segment, or one of
    #   RulePath::UNJOINABLE_CAUSES);
    # - :missing_column — a field_name that is no column of its table
    #   ({RuleColumn#missing?}); `name` is the column as written, `model` the
    #   model whose table lacks it.
    #
    # A rule PermissionSetRule refuses on save never gets here; one saved
    # before the check, or written past the model, does. Whatever cannot be
    # told — a Resource named after no model, a table that does not exist, a
    # name qualified with a table that is none of the rule's, a model file
    # that raises while it loads — is no problem here (see
    # RuleColumn.for_rule): the admin and the audit describe, they never
    # fail on a model the application cannot load.
    #
    # @example
    #   problem = RuleProblem.for(rule)
    #   problem&.kind  # => :missing_column
    #   problem&.name  # => "stauts"
    #   problem&.key   # => :missing_column
    RuleProblem = Data.define(:kind, :name, :model, :cause) do
      # `cause` is optional: a column problem has none.
      def initialize(kind:, name:, model:, cause: nil)
        super
      end

      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.for(rule)
        of_path(rule) || of_column(rule)
      end

      # The rule's path problem, nil when it has none (a filter rule never
      # has one: its path is not joined).
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.of_path(rule)
        model = RuleColumn.rule_model(rule)
        return unless model && rule.join_rule?

        path = RulePath.follow(model, RuleColumn.path_segments(rule.field_accessor_path))
        new(kind: path.reason, name: path.segment, model: path.owner, cause: path.cause) if path.broken?
      rescue *RuleColumn::UNTELLABLE
        nil
      end

      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.of_column(rule)
        column = RuleColumn.for_rule(rule)
        return unless column&.missing?

        new(kind: :missing_column, name: rule.field_name.to_s.split('.').last, model: column.model)
      end

      # The rule's path and field name as stored (a filter rule's path is not joined).
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [String] e.g. "ownr.owner_id"
      def self.written_field(rule)
        path = rule.field_accessor_path.presence if rule.join_rule?
        [path, rule.field_name].compact.join('.')
      end

      # Whether the problem is the rule's association path (not its column).
      def path? = kind != :missing_column

      # What the problem is called in the locale files: the kind, keyed by
      # its cause where it has one — :missing_column, :unknown_association,
      # :empty_association, :unjoinable_polymorphic, ... (the admin's
      # `ui.rules.problems.<key>`, the model's validation message).
      #
      # @return [Symbol]
      def key
        return :empty_association if cause == :empty_segment
        return kind unless kind == :unjoinable_association && cause

        :"unjoinable_#{cause}"
      end

      # The validation error PermissionSetRule adds for it, in the current locale.
      #
      # @return [String]
      def validation_message
        message_key = key == :missing_column ? :unknown_column : key
        I18n.t("permission_forge.validations.permission_set_rule.#{message_key}",
               association: name, model: model.name, default: RULE_PROBLEM_MESSAGES.fetch(message_key))
      end
    end
  end
end
