module PermissionForge
  # The service objects hosts call (`Service.call(...)`): assignment, erasure, filtering, auditing and cloning.
  # Each public service documents its arguments and result; helpers under this namespace are `@api private`.
  #
  # @api public
  module Services
    # WARNING: These strategies provide display-level obfuscation only.
    # They do NOT constitute GDPR-compliant anonymization or pseudonymization.
    # See docs/gdpr_masking_disclaimer.md for details.
    #
    # @api public
    class MaskValue
      BUILT_IN_STRATEGIES = {
        'full' => :mask_full,
        'email' => :mask_email,
        'last4' => :mask_last4,
        'first1_last4' => :mask_first1_last4
      }.freeze

      STRATEGIES = BUILT_IN_STRATEGIES.keys.freeze
      MASK_CHAR = '*'.freeze

      # @return [Hash{String => #call}] the built-in strategies merged with `config.custom_mask_strategies`
      def self.strategies
        custom = PermissionForge.configuration.custom_mask_strategies
        return BUILT_IN_STRATEGIES if custom.blank?

        BUILT_IN_STRATEGIES.merge(custom)
      end

      # Masks a value with a built-in or custom strategy.
      # @param value [Object]
      # @param strategy [String] `full`, `email`, `last4`, `first1_last4` or a custom one
      # @return [Object] the masked value (nil stays nil)
      def self.call(value, strategy: 'full')
        return value if value.nil?

        str = value.to_s
        return str if str.empty?

        new(str, strategy).call
      end

      def initialize(value, strategy)
        @value = value
        @strategy = strategy
        all_strategies = self.class.strategies
        return if all_strategies.key?(@strategy)

        raise ArgumentError,
              "Unknown mask strategy: #{strategy.inspect}. Valid strategies: #{all_strategies.keys.join(', ')}"
      end

      # @return [Object] the masked value
      def call
        all_strategies = self.class.strategies
        strategy_ref = all_strategies[@strategy]

        if strategy_ref.is_a?(Symbol)
          send(strategy_ref)
        else
          strategy_ref.call(@value)
        end
      end

      private

      def mask_full
        MASK_CHAR * 8
      end

      def mask_email
        return mask_full unless @value.include?('@')

        local, domain = @value.split('@', 2)
        masked_local = local.length > 1 ? "#{local[0]}#{MASK_CHAR * 3}" : MASK_CHAR
        "#{masked_local}@#{domain}"
      end

      def mask_last4
        return mask_full if @value.length <= 4

        "#{MASK_CHAR * (@value.length - 4)}#{@value[-4..]}"
      end

      def mask_first1_last4
        return mask_full if @value.length <= 5

        "#{@value[0]}#{MASK_CHAR * (@value.length - 5)}#{@value[-4..]}"
      end
    end
  end
end
