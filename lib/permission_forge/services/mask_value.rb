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
    # A strategy name this app does not know — a field row written past the
    # model, a custom strategy since removed from `config.custom_mask_strategies`,
    # a blank — never raises on a read path: {.call} masks fully
    # ({FALLBACK_STRATEGY}) and reports the name once per process (a warning
    # and the {UNKNOWN_STRATEGY_EVENT} notification); `rake permission_forge:audit`
    # lists the rows (`unknown_mask_strategies`). {.call!} is the strict form
    # for the admin preview and the validation.
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
      # The strategy applied in place of one this app does not know: the strictest built-in.
      FALLBACK_STRATEGY = 'full'.freeze
      # Published once per process for each strategy name this app does not know
      # (payload: `strategy`, the name as stored; `fallback`, what was applied).
      UNKNOWN_STRATEGY_EVENT = 'mask_strategy_unknown.permission_forge'.freeze

      REPORTED_MUTEX = Mutex.new
      @reported = Set.new

      # @return [Hash{String => #call}] the built-in strategies merged with `config.custom_mask_strategies`
      def self.strategies
        custom = PermissionForge.configuration.custom_mask_strategies
        return BUILT_IN_STRATEGIES if custom.blank?

        BUILT_IN_STRATEGIES.merge(custom.transform_keys(&:to_s))
      end

      # Whether `strategy` names a built-in or configured custom strategy.
      # @param strategy [String, Symbol, nil]
      # @return [Boolean]
      def self.known?(strategy)
        !strategy.nil? && strategies.key?(strategy.to_s)
      end

      # Masks a value with a built-in or custom strategy. A strategy this app
      # does not know masks fully and is reported once per process per name:
      # a read never raises.
      # @param value [Object]
      # @param strategy [String] `full`, `email`, `last4`, `first1_last4` or a custom one
      # @return [Object] the masked value (nil stays nil)
      def self.call(value, strategy: FALLBACK_STRATEGY)
        return value if value.nil?

        str = value.to_s
        return str if str.empty?

        new(str, resolve(strategy)).call
      end

      # Masks a value, strictly: a strategy this app does not know raises (the
      # admin preview, the validation — never a read path).
      # @param value [Object]
      # @param strategy [String]
      # @return [Object] the masked value (nil stays nil)
      # @raise [ArgumentError] for a strategy this app does not know
      def self.call!(value, strategy: FALLBACK_STRATEGY)
        raise ArgumentError, unknown_message(strategy) unless known?(strategy)

        call(value, strategy: strategy)
      end

      # Forgets which unknown strategies were reported (for tests).
      # @return [void]
      def self.reset_reports!
        REPORTED_MUTEX.synchronize { @reported.clear }
      end

      # The strategy to apply: the name when this app knows it, else the
      # fallback, the name reported once.
      def self.resolve(strategy)
        return strategy.to_s if known?(strategy)

        report_unknown(strategy.to_s)
        FALLBACK_STRATEGY
      end

      def self.report_unknown(name)
        return unless REPORTED_MUTEX.synchronize { @reported.add?(name) }

        Rails.logger&.warn("[PermissionForge] #{unknown_message(name)} Values are masked fully until the field row or " \
                           'config.custom_mask_strategies is fixed (rake permission_forge:audit lists the rows).')
        ActiveSupport::Notifications.instrument(UNKNOWN_STRATEGY_EVENT, strategy: name, fallback: FALLBACK_STRATEGY)
      end

      def self.unknown_message(strategy)
        "Unknown mask strategy: #{strategy.inspect}. Valid strategies: #{strategies.keys.join(', ')}."
      end
      private_class_method :resolve, :report_unknown, :unknown_message

      # @param value [String] a non-empty String
      # @param strategy [String] a known strategy (see .resolve)
      def initialize(value, strategy)
        @value = value
        @strategy = strategy
      end

      # @return [Object] the masked value
      def call
        strategy_ref = self.class.strategies[@strategy]

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
