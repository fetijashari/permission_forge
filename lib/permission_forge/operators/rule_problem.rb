# frozen_string_literal: true

module PermissionForge
  module Operators
    # The English of RuleProblem#validation_message, by RuleProblem#message_key
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
      unknown_column: 'names %<name>s, which is not a column of %<model>s',
      unknown_table: 'names %<name>s, which is no table of this database',
      invalid_operator: 'is not a valid operator',
      invalid_join_type: 'is not a valid join type',
      unusable_value: 'is not a value %<model>s.%<name>s can hold'
    }.freeze

    # Why a saved rule matches nothing: the one taxonomy of a "broken" rule
    # ({KINDS}), which the model's validations, the applier's `none`
    # (Services::PermissionRuleApplier), the audit (Services::SecurityAudit's
    # rule check), the admin's Home ("Rules that match nothing"), the admin's
    # rule sentences and the RLS policy's `FALSE` all read.
    #
    # - :unknown_join_type — a join type none of PermissionRuleApplier::JOIN_METHODS;
    #   `name` is the join type as stored;
    # - :unknown_association / :unjoinable_association — a join rule whose
    #   association path cannot be followed ({RulePath#broken?}); `name` is
    #   the segment, `model` the model it was looked up in, `cause` why
    #   ({RulePath#cause}: :empty_segment, or one of
    #   RulePath::UNJOINABLE_CAUSES);
    # - :unknown_operator — an operator the Registry does not have; `name`
    #   is the operator as stored;
    # - :missing_column — a field_name that is no column of its table
    #   ({RuleColumn#missing?}), or not a name at all ({RuleColumn#malformed?});
    #   `name` is the column as written, `model` the model whose table lacks it;
    # - :unknown_table — a field_name qualified with a table that is none of
    #   the rule's and not in the database ({RuleColumn#unresolvable?});
    #   `name` is the qualifier;
    # - :unusable_value — a value the column cannot hold ({ValueTyping::UNUSABLE});
    #   `name` is the column, `value` the value as stored. Valid to save, as
    #   documented ("A value the column cannot hold"); listed and denied.
    #
    # The kinds are checked in the order the applier decides them, so a rule
    # with several problems is named by the one that denies it first. A rule
    # PermissionSetRule refuses on save never gets here; one saved before the
    # check, or written past the model, does. Whatever cannot be told — a
    # Resource named after no model, a model file that raises while it loads
    # — is no column or value problem here (see RuleColumn.for_rule): the
    # admin and the audit describe, they never fail on a model the
    # application cannot load. An operator or join type is judged whatever
    # the model.
    #
    # @example
    #   problem = RuleProblem.for(rule)
    #   problem&.kind  # => :missing_column
    #   problem&.name  # => "stauts"
    #   problem&.key   # => :missing_column
    class RuleProblem < Data.define(:kind, :name, :model, :cause, :value)
      # Every kind, in the order the applier decides them. A new kind needs a
      # fixture in test/support/rule_problem_fixtures.rb, an entry in
      # RULE_PROBLEM_MESSAGES (or MESSAGE_KEYS), one in REMEDIES, and the
      # message and the `ui.rules.problems` sentence in en, sq and mk.
      KINDS = %i[unknown_join_type unknown_association unjoinable_association unknown_operator missing_column
                 unknown_table unusable_value].freeze
      # What the admin changes to correct the rule, by kind — the rule
      # builder's control (`permission_set_rules.builder.problem_fixes.<remedy>`):
      # the join type (Advanced), the relationship, the condition, the field,
      # or the value.
      REMEDIES = { unknown_join_type: :join, unknown_association: :path, unjoinable_association: :path,
                   unknown_operator: :operator, missing_column: :field, unknown_table: :field,
                   unusable_value: :value }.freeze
      # The kinds that are the rule's association path (not its column or value).
      PATH_KINDS = %i[unknown_association unjoinable_association].freeze
      # The kinds whose `name` is a name that is not there, shown as stored.
      VERBATIM_KINDS = %i[missing_column unknown_association unknown_operator unknown_join_type unknown_table].freeze
      # key => the validations.permission_set_rule.* message, where it is not the key itself.
      MESSAGE_KEYS = { missing_column: :unknown_column, unknown_operator: :invalid_operator,
                       unknown_join_type: :invalid_join_type }.freeze
      # What `current_user` is typed as when a stored value is judged: an id
      # is a number or its text, whoever the user is, never a boolean or a date.
      ANY_USER_ID = 0

      # `cause` and `value` are optional: a column problem has no cause, only a value problem a value.
      def initialize(kind:, name:, model:, cause: nil, value: nil)
        super
      end

      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.for(rule)
        of_join_type(rule) || of_path(rule) || of_operator(rule) || of_column_or_value(rule)
      end

      # A join rule whose join type is none the applier joins by.
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.of_join_type(rule)
        return unless rule.join_rule?

        join_type = rule.join_type.to_s
        return if Services::PermissionRuleApplier::JOIN_METHODS.key?(join_type)

        new(kind: :unknown_join_type, name: join_type, model: RuleColumn.rule_model(rule))
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

      # An operator the Registry does not have.
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.of_operator(rule)
        operator = rule.operator.to_s
        return if Registry.strategies.key?(operator)

        new(kind: :unknown_operator, name: operator, model: RuleColumn.rule_model(rule))
      end

      # The rule's column problem, else its value problem — the column looked up once.
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [RuleProblem, nil]
      def self.of_column_or_value(rule)
        column = RuleColumn.for_rule(rule)
        of_column(rule, column) || of_value(rule, column)
      end

      # @param rule [PermissionForge::PermissionSetRule]
      # @param column [RuleColumn, nil] the rule's column (RuleColumn.for_rule)
      # @return [RuleProblem, nil]
      def self.of_column(rule, column = RuleColumn.for_rule(rule))
        return unless column

        field_name = rule.field_name.to_s
        if column.malformed?
          new(kind: :missing_column, name: field_name, model: RuleColumn.rule_model(rule))
        elsif column.missing?
          new(kind: :missing_column, name: field_name.split('.').last, model: column.model)
        elsif column.unresolvable?
          new(kind: :unknown_table, name: field_name.split('.')[-2], model: RuleColumn.rule_model(rule))
        end
      end

      # A value the column cannot hold, typed as the applier types it
      # (ValueTyping; `current_user` as ANY_USER_ID). Only for a column that
      # was found: the column's own problem comes first. A blank value is
      # none (the presence validation's business; a rule being built has
      # none yet).
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @param column [RuleColumn, nil] the rule's column (RuleColumn.for_rule)
      # @return [RuleProblem, nil]
      def self.of_value(rule, column = RuleColumn.for_rule(rule))
        return unless column_found?(column) && rule.field_value.present? && unusable_value?(rule, column)

        new(kind: :unusable_value, name: rule.field_name.to_s.split('.').last, model: column.model || RuleColumn.rule_model(rule),
            value: rule.field_value)
      end

      def self.column_found?(column)
        !column.nil? && !column.malformed? && !column.missing? && !column.unresolvable?
      end

      def self.unusable_value?(rule, column)
        operator = rule.operator.to_s
        value = rule.field_value
        value = ANY_USER_ID if ValueTyping.current_user?(operator, value)
        ValueTyping.call(operator, value, column).equal?(ValueTyping::UNUSABLE)
      rescue *RuleColumn::UNTELLABLE
        false
      end
      private_class_method :column_found?, :unusable_value?

      # The rule's path and field name as stored (a filter rule's path is not joined).
      #
      # @param rule [PermissionForge::PermissionSetRule]
      # @return [String] e.g. "ownr.owner_id"
      def self.written_field(rule)
        path = rule.field_accessor_path.presence if rule.join_rule?
        [path, rule.field_name].compact.join('.')
      end

      # Whether the problem is the rule's association path (not its column,
      # operator, join type or value).
      def path? = PATH_KINDS.include?(kind)

      # What the admin changes to correct it (REMEDIES): :join, :path,
      # :operator, :field or :value.
      #
      # @return [Symbol]
      def remedy = REMEDIES.fetch(kind)

      # Whether `name` is shown as stored (`onwer_id`, `ownr`, `regex`,
      # `inner`, `nosuch`): a name that is not there has no label — humanized
      # it would read like a real field.
      def verbatim? = VERBATIM_KINDS.include?(kind)

      # The admin's sentence for it, under `ui.rules.problems`: the key, by
      # cause where it has one; `_html` where the name or the value is drawn
      # as stored (in code).
      #
      # @return [Symbol]
      def ui_key
        return key if cause

        :"#{kind}#{'_html' if verbatim? || value}"
      end

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

      # The `permission_forge.validations.permission_set_rule.*` key of the
      # validation message: the key, or the message the attribute's own
      # validator gives (an operator or join type that is not one).
      #
      # @return [Symbol]
      def message_key
        MESSAGE_KEYS.fetch(key, key)
      end

      # The validation error PermissionSetRule adds for it, in the current locale.
      #
      # @return [String]
      def validation_message
        I18n.t("permission_forge.validations.permission_set_rule.#{message_key}",
               association: name, name: name, model: model&.name, value: value,
               default: RULE_PROBLEM_MESSAGES.fetch(message_key))
      end
    end
  end
end
