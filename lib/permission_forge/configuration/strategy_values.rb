# frozen_string_literal: true

module PermissionForge
  class Configuration
    # The strategy options that decide whether something is allowed. Each
    # writer takes a Symbol from its list, or that Symbol's String
    # ('block' is :block), and raises ConfigurationError for anything else,
    # at assignment time (the initializer). Before, a String was compared
    # with a Symbol and read as an unknown value: for some options that
    # failed open ('block' for response_filter_nil_user_strategy was
    # :bypass). Prepended, so it wraps the plain writers declared in
    # Configuration and its sub-settings.
    #
    # @api private
    module StrategyValues
      ALLOWED = {
        nil_user_strategy: %i[bypass raise deny],
        no_read_access_strategy: %i[rules_only deny],
        response_filter_nil_user_strategy: %i[bypass block],
        masked_write_protection: %i[skip raise off],
        masked_attributes_nil_user_strategy: %i[bypass hide],
        action_guard_nil_user_strategy: %i[bypass deny raise],
        admin_tenantless_access: %i[deny allow],
        unconfigured_action_strategy: %i[allow block],
        extra_fields_default_access: %i[grant unconfigured]
      }.freeze

      # nil or blank means "follow nil_user_strategy".
      BLANK_ALLOWED = %i[action_guard_nil_user_strategy].freeze

      ALLOWED.each_key do |option|
        define_method(:"#{option}=") do |value|
          super(StrategyValues.strategy(option, value))
        end
      end

      # @return [Symbol, nil]
      # @raise [PermissionForge::ConfigurationError] for a value not in ALLOWED[option]
      def self.strategy(option, value)
        blank_allowed = BLANK_ALLOWED.include?(option)
        return nil if blank_allowed && value.to_s.strip.empty?

        allowed = ALLOWED.fetch(option)
        symbol = as_symbol(value)
        return symbol if allowed.include?(symbol)

        raise PermissionForge::ConfigurationError,
              "#{option} must be one of #{allowed.map(&:inspect).join(', ')} (or its String)" \
              "#{' or nil' if blank_allowed}; got #{value.inspect}"
      end

      # A Symbol as is, a String as its Symbol, anything else nil.
      def self.as_symbol(value)
        value.to_s.to_sym if value.is_a?(String) || value.is_a?(Symbol)
      end
    end
  end
end
