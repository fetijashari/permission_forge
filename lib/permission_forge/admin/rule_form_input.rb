# frozen_string_literal: true

module PermissionForge
  module Admin
    # Reads RuleForm's inputs, either from the submitted rule-builder params or
    # from a saved PermissionSetRule. Returns a hash keyed by RuleForm reader
    # (name, path, field_name, operator, value, values, value_from, value_to,
    # current_user, include_nulls, failure_message, join, is_active).
    module RuleFormInput
      # @param attrs [Hash{String => Object}] stringified params
      def self.from_params(attrs)
        param_path(attrs).merge(param_values(attrs), param_options(attrs))
      end

      # @param rule [PermissionSetRule, nil] nil for a new rule
      # A new rule starts on the model's defaults (include_nulls among them).
      def self.from_rule(rule)
        rule ||= PermissionForge::PermissionSetRule.new(operator: 'equal', is_active: true)
        path = rule_path(rule)
        path.merge(rule_values(rule.field_value.to_s, RuleForm::ARITY.fetch(path[:operator], :one)), rule_options(rule))
      end

      def self.param_path(attrs)
        path = Array(attrs['path']).map(&:to_s).compact_blank
        # The steps kept by a "remove" button: a count of them (0 up to the
        # path's length), else none removed (ParamShapes.integer).
        keep = ParamShapes.integer(attrs['remove_step'], default: nil, range: 0..path.size)
        # The operator as posted: one that is not a condition is refused by
        # RuleForm#valid?, never rewritten to another.
        { name: attrs['name'].to_s.strip, path: keep ? path.first(keep) : path,
          field_name: attrs['field_name'].to_s, operator: attrs.key?('operator') ? attrs['operator'].to_s : 'equal' }
      end

      def self.param_values(attrs)
        { value: stripped(attrs['value']), values: list_values(attrs),
          value_from: stripped(attrs['value_from']), value_to: stripped(attrs['value_to']),
          current_user: flag(attrs, 'current_user', default: false) }
      end

      # Checked list values plus comma-separated free text.
      def self.list_values(attrs)
        values = Array(attrs['values']) + attrs['values_text'].to_s.split(',')
        values.map { |v| stripped(v) }.compact_blank.uniq
      end

      def self.param_options(attrs)
        { include_nulls: flag(attrs, 'include_nulls', default: false), failure_message: stripped(attrs['failure_message']),
          join: allowed(attrs['join'], RuleForm::JOINS, 'auto'),
          is_active: flag(attrs, 'is_active', default: true) }
      end

      # A checkbox of the builder, through the one boolean reading of the
      # admin and the API (ParamShapes.flag): the box absent (unchecked, no
      # hidden field) is `default`; a value that is no boolean raises
      # ParamShapes::InvalidFlag, which the admin answers with a flash.
      def self.flag(attrs, key, default:)
        attrs[key].nil? ? default : ParamShapes.flag(key, attrs[key])
      end

      # A filter rule's path is never joined (PermissionSetRule#join_rule?,
      # the one definition): the builder does not load one, so saving the
      # rule again keeps it a filter rule.
      def self.rule_path(rule)
        path = rule.join_rule? ? rule.field_accessor_path.to_s.split('.').compact_blank : []
        { name: Prefill.text(rule, :name), path: path, field_name: rule.field_name.to_s, operator: rule.operator.presence || 'equal' }
      end

      def self.rule_values(raw, arity)
        current_user = raw == RuleForm::CURRENT_USER
        value_from, value_to = arity == :range ? raw.split(',', 2).map(&:strip) : ['', '']
        { current_user: current_user, value: current_user ? '' : raw,
          values: arity == :list ? raw.split(',').map(&:strip) : [], value_from: value_from, value_to: value_to }
      end

      def self.rule_options(rule)
        { include_nulls: rule.include_nulls == true, failure_message: Prefill.text(rule, :failure_message),
          join: rule.join_rule? ? rule.join_type : 'auto', is_active: rule.is_active != false }
      end

      def self.allowed(value, choices, fallback)
        value = value.to_s
        choices.include?(value) ? value : fallback
      end

      def self.stripped(value)
        value.to_s.strip
      end
    end
  end
end
