module PermissionForge
  module Operators
    # Operator-specific checks of a rule's `field_value` (`between` takes exactly two values, `in` at least one).
    # Add a check with one entry in `VALIDATORS`.
    #
    # @api public
    module Validations
      VALUE_REQUIRED_MESSAGE = lambda {
        I18n.t('permission_forge.validations.permission_set_rule.value_required',
               default: 'must not be blank for this operator')
      }

      NUMERIC_REQUIRED_MESSAGE = lambda {
        I18n.t('permission_forge.validations.permission_set_rule.numeric_or_date_required',
               default: 'must be a numeric or date value for comparison operators')
      }

      VALUE_NOT_EXPECTED_MESSAGE = lambda {
        I18n.t('permission_forge.validations.permission_set_rule.value_not_expected',
               default: 'does not require a value for this operator')
      }

      SINGLE_VALUE_VALIDATOR = lambda { |values|
        return unless values.empty?

        { field: :field_value, message: VALUE_REQUIRED_MESSAGE.call }
      }

      NUMERIC_VALIDATOR = lambda { |values|
        return if values.empty?
        return if values.all? { |v| v.match?(/\A-?\d+(\.\d+)?\z/) || parseable_date?(v) }

        { field: :field_value, message: NUMERIC_REQUIRED_MESSAGE.call }
      }

      NULL_OPERATOR_VALIDATOR = lambda { |values|
        return if values.empty?

        { field: :field_value, message: VALUE_NOT_EXPECTED_MESSAGE.call }
      }

      VALIDATORS = {
        'between' => lambda { |values|
          return if values.size == 2

          { field: :field_value,
            message: I18n.t('permission_forge.validations.permission_set_rule.between_requires_two_values',
                            default: 'must contain exactly 2 comma-separated values for between operator') }
        },
        'in' => lambda { |values|
          return unless values.empty?

          { field: :field_value,
            message: I18n.t('permission_forge.validations.permission_set_rule.in_requires_values',
                            default: 'must contain at least 1 comma-separated value') }
        },
        'not_in' => lambda { |values|
          return unless values.empty?

          { field: :field_value,
            message: I18n.t('permission_forge.validations.permission_set_rule.in_requires_values',
                            default: 'must contain at least 1 comma-separated value') }
        },
        'equal' => SINGLE_VALUE_VALIDATOR,
        'not_equal' => SINGLE_VALUE_VALIDATOR,
        'contains' => SINGLE_VALUE_VALIDATOR,
        'not_contains' => SINGLE_VALUE_VALIDATOR,
        'starts_with' => SINGLE_VALUE_VALIDATOR,
        'ends_with' => SINGLE_VALUE_VALIDATOR,
        'greater_than' => NUMERIC_VALIDATOR,
        'less_than' => NUMERIC_VALIDATOR,
        'greater_than_or_equal' => NUMERIC_VALIDATOR,
        'less_than_or_equal' => NUMERIC_VALIDATOR,
        'is_null' => NULL_OPERATOR_VALIDATOR,
        'is_not_null' => NULL_OPERATOR_VALIDATOR
      }.freeze

      # The operators that take no value (the null checks): the ones whose
      # validator refuses any value.
      VALUELESS = VALIDATORS.select { |_, validator| validator.equal?(NULL_OPERATOR_VALIDATOR) }.keys.freeze

      # @return [Boolean] whether `operator` takes no value
      def self.valueless?(operator)
        VALUELESS.include?(operator.to_s)
      end

      # @param operator [String] an operator of PermissionSetRule
      # @param field_value [String] the rule's value
      # @return [Hash, nil] `{ field:, message: }` when the value is invalid for the operator, else nil
      def self.validate(operator, field_value)
        return if operator.blank? || field_value.blank?
        # 'current_user' is a special substitution token valid for all operators
        return if field_value.to_s.strip == 'current_user'

        validator = VALIDATORS[operator]
        return unless validator

        parsed = field_value.to_s.split(',').map(&:strip).reject(&:blank?)
        validator.call(parsed)
      end

      def self.parseable_date?(value)
        Date.parse(value)
        true
      rescue ArgumentError, TypeError
        false
      end
      private_class_method :parseable_date?
    end
  end
end
