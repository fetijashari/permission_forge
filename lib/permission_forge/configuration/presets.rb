# frozen_string_literal: true

module PermissionForge
  class Configuration
    # `config.preset`: a named set of values for the options that decide
    # whether something fails open, applied as a layer of defaults under
    # the settings the host makes itself.
    #
    #   :compat (default) — the library defaults, as every version had them
    #   :strict           — every fail-open default of the README's
    #                       "Production hardening checklist" closed, and the
    #                       settings that are already closed kept so
    #
    # A setting made explicitly always wins, before or after `preset =`, in
    # the same configure block or a later one: the preset only fills the
    # options nobody set. A String is taken as its Symbol; anything else
    # raises ConfigurationError. SecurityAudit reports the preset and, under
    # :strict, every option set looser than the preset.
    #
    # The options that need host code to close (an authenticated
    # base_controller_class, admin_assignment_authorization,
    # audit_log_authorization, a request_context_resolver, user_active_check)
    # are not in a preset. Nor is masked_attributes_nil_user_strategy
    # (OPT_IN): :hide makes jobs and mailers that read masked models with no
    # user see hidden values, a cost each app must choose; it stays :bypass
    # under every preset.
    #
    # @api public
    module Presets
      # The library defaults of every option a preset decides: what
      # Configuration.new starts with (a test pins the two together).
      COMPAT = {
        # fail open by default (the checklist)
        nil_user_strategy: :bypass,
        response_filter_nil_user_strategy: :bypass,
        auto_query_scoping: :off,
        no_read_access_strategy: :rules_only,
        unconfigured_action_strategy: :allow,
        action_guard_nil_user_strategy: nil,
        conditional_sets_strict_mode: false,
        mask_virtual_attributes: false,
        extra_fields_default_access: :grant,
        cache_backend: :memory,
        # closed by default
        api_require_authorization: true,
        admin_tenantless_access: :deny,
        nested_attributes_parent_fallback: false,
        unconfigured_field_strategy: :block
      }.freeze

      STRICT = COMPAT.merge(
        nil_user_strategy: :deny,
        response_filter_nil_user_strategy: :block,
        auto_query_scoping: :filter_only,
        no_read_access_strategy: :deny,
        unconfigured_action_strategy: :block,
        action_guard_nil_user_strategy: :deny,
        conditional_sets_strict_mode: true,
        mask_virtual_attributes: :auto,
        extra_fields_default_access: :unconfigured,
        cache_backend: :rails_cache
      ).freeze

      PRESETS = { compat: COMPAT, strict: STRICT }.freeze

      # Fail-open defaults of the hardening checklist that no preset closes:
      # an explicit choice with a documented cost.
      OPT_IN = %i[masked_attributes_nil_user_strategy].freeze
      OPTIONS = COMPAT.keys.freeze

      # When an option counts as closed with a value other than the :strict
      # one: receives (value, configuration).
      ALSO_CLOSED = {
        nil_user_strategy: ->(value, _config) { value == :raise },
        # nil follows nil_user_strategy
        action_guard_nil_user_strategy: ->(_value, config) { !config.action_guard_nil_user_bypass? },
        mask_virtual_attributes: ->(value, _config) { [true, 'auto'].include?(value) },
        # no cache at all, or a shared store the host built
        cache_backend: ->(value, _config) { value == :null || value.is_a?(ActiveSupport::Cache::Store) }
      }.freeze

      # Each writer of an option a preset decides marks the option as set by
      # the host (after the value passed validation).
      OPTIONS.each do |option|
        define_method(:"#{option}=") do |value|
          super(value)
          @explicit_options << option
        end
      end

      # @return [Symbol] :compat or :strict
      attr_reader :preset

      # @raise [PermissionForge::ConfigurationError] for anything but :strict
      #   or :compat (or its String)
      def preset=(value)
        name = StrategyValues.as_symbol(value)
        unless PRESETS.key?(name)
          raise PermissionForge::ConfigurationError,
                "preset must be one of #{PRESETS.keys.map(&:inspect).join(', ')} (or its String); got #{value.inspect}"
        end

        backend = @cache_backend
        @preset = name
        PRESETS.fetch(name).each do |option, preset_value|
          instance_variable_set(:"@#{option}", preset_value) unless @explicit_options.include?(option)
        end
        # A store built from the old backend (preset set outside configure,
        # which rebuilds it anyway) is rebuilt.
        reset_cache_store! if @cache_store && !backend.equal?(@cache_backend)
      end

      # @param option [Symbol]
      # @return [Boolean] whether the host set the option itself (not the preset)
      def explicitly_set?(option)
        @explicit_options.include?(option.to_sym)
      end

      # The options whose value is looser than the :strict preset's — under
      # :strict, the ones the host overrode.
      #
      # @return [Hash{Symbol => Object}] option => current value
      def options_looser_than_strict
        STRICT.each_with_object({}) do |(option, strict_value), looser|
          value = public_send(option)
          value = value.to_sym if value.is_a?(String) # 'block' is :block, as the strategy writers take it
          next if value == strict_value || ALSO_CLOSED[option]&.call(value, self)

          looser[option] = value
        end
      end

      private

      def set_preset_defaults
        @preset = :compat
        @explicit_options = Set.new
      end
    end
  end
end
