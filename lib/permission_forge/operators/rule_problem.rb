# frozen_string_literal: true

module PermissionForge
  module Operators
    # The English of RuleProblem#validation_message, by kind (translated under
    # permission_forge.validations.permission_set_rule).
    RULE_PROBLEM_MESSAGES = {
      unknown_association: 'names %<association>s, which is not an association of %<model>s',
      unjoinable_association: 'names %<association>s, an association of %<model>s that a rule cannot join ' \
                              '(polymorphic, or its class cannot be loaded)',
      missing_column: 'is not a column of %<model>s'
    }.freeze

    # Why a saved rule matches nothing because it names something that is not
    # there: the one definition of a "broken" rule, which the audit
    # (`missing_rule_columns`), the admin's Home ("Needs attention") and the
    # admin's rule sentences all ask.
    #
    # - :unknown_association / :unjoinable_association — a join rule whose
    #   association path cannot be followed ({RulePath#broken?}); `name` is
    #   the segment, `model` the model it was looked up in;
    # - :missing_column — a field_name that is no column of its table
    #   ({RuleColumn#missing?}); `name` is the column as written, `model` the
    #   model whose table lacks it.
    #
    # A rule PermissionSetRule refuses on save never gets here; one saved
    # before the check, or written past the model, does. Whatever cannot be
    # told — a Resource named after no model, a table that does not exist, a
    # name qualified with a table that is none of the rule's — is no problem
    # here (see RuleColumn.for_rule).
    #
    # @example
    #   problem = RuleProblem.for(rule)
    #   problem&.kind  # => :missing_column
    #   problem&.name  # => "stauts"
    RuleProblem = Data.define(:kind, :name, :model) do
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
        new(kind: path.reason, name: path.segment, model: path.owner) if path.broken?
      rescue NameError, ArgumentError, ActiveRecord::ActiveRecordError
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

      # The validation error PermissionSetRule adds for it, in the current locale.
      #
      # @return [String]
      def validation_message
        key = kind == :missing_column ? 'unknown_column' : kind
        I18n.t("permission_forge.validations.permission_set_rule.#{key}", association: name, model: model.name,
                                                                          default: RULE_PROBLEM_MESSAGES.fetch(kind))
      end
    end
  end
end
