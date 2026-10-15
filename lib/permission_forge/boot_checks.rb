# frozen_string_literal: true

module PermissionForge
  # What the engine checks while the host app boots: run (from
  # config.after_initialize) and ensure_tenancy_gem! (from an initializer).
  #
  # The configuration checks need nothing. The database steps are advisory
  # warnings or idempotent work, and they must never abort a boot: a Docker
  # build precompiles assets with no database, a worker can start while the
  # database fails over. The database is pinged once (db_available?); a step
  # that loses it midway is skipped (DATABASE_STEP_ERRORS) and the next step
  # runs. Anything else a step raises (a ConfigurationError) still stops the
  # boot.
  #
  # @api private
  module BootChecks
    # Errors that mean "the database is not there (yet)": gone, refused, not
    # created, not migrated.
    DATABASE_STEP_ERRORS = [ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid].freeze

    # The boot steps that read the database, in order. Each runs on its
    # own: one that loses the database is skipped (database_step).
    DATABASE_STEPS = {
      unmasked_gdpr_fields: ->(config) { warn_unmasked_gdpr_fields(config) unless config.gdpr_defaults },
      conditional_sets: ->(config) { warn_conditional_sets_without_context(config) },
      join_rules: ->(config) { QueryScopingWarnings.warn_join_rules_not_auto_scoped(config) },
      row_level_security: ->(config) { QueryScopingWarnings.warn_rls_misconfiguration(config) },
      # The missing-table warning, auditing switched off, one shared login.
      audit: ->(config) { Audit::BootWarnings.call(config) },
      # The audit settings in force, when they differ from the last recorded
      # ones. Never in the test environment (it is invoked directly there).
      audit_settings: ->(_config) { Audit::SettingsObserver.call unless Rails.env.test? },
      # Auto-applied masking (MaskedModels), kept in step by MaskingSync.
      masked_attributes: ->(_config) { MaskingSync.boot! }
    }.freeze

    class << self
      # @param config [Configuration]
      def run(config)
        config.validate_gdpr_explicit_choice!
        warn_configuration(config)
        return database_unreachable unless db_available?

        DATABASE_STEPS.each { |name, step| database_step(name) { step.call(config) } }
      end

      # HasTenantScoping silently skips the scope when the gem is absent,
      # which would leave every tenant's permission data visible to every
      # other tenant — refuse to boot instead.
      #
      # @param config [Configuration]
      # @raise [ConfigurationError]
      def ensure_tenancy_gem!(config)
        return unless config.tenant_enabled?
        return if defined?(::ActsAsTenant)

        raise PermissionForge::ConfigurationError,
              "config.tenant_model is set to '#{config.tenant_model}' but the acts_as_tenant gem is not loaded. " \
              'Add `gem "acts_as_tenant"` to your Gemfile, or set config.tenant_model = nil.'
      end

      # Conditional permission sets (session flag / IP / login hours) with a
      # request_context_resolver that returns an empty context evaluate as
      # unconditional (always active) unless conditional_sets_strict_mode is on.
      def warn_conditional_sets_without_context(config)
        # Strict mode denies conditional sets under blank context (fail closed),
        # so the always-active footgun doesn't apply — no warning needed.
        return if config.conditional_sets_strict_mode

        conditional_sets = PermissionForge::PermissionSet.conditional
        return unless conditional_sets.exists?
        return unless resolved_context(config).empty?

        Rails.logger.warn '[PermissionForge] SECURITY warning: ' \
                          "#{conditional_sets.count} permission set(s) use activation conditions " \
                          '(session flag, allowed_ips, or login hours) but request_context_resolver ' \
                          'returns empty context. These sets will evaluate as unconditional ' \
                          '(ALWAYS ACTIVE) — IP/hours/consent restrictions are NOT enforced. ' \
                          'Configure config.request_context_resolver, or set ' \
                          'config.conditional_sets_strict_mode = true to fail closed.'
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      def warn_api_authorization_gap(config)
        return unless config.api_enabled
        return if config.api_require_authorization
        return if config.api_action_authorization && config.api_assignment_authorization

        Rails.logger&.warn '[PermissionForge] SECURITY warning: API is enabled, ' \
                           'config.api_require_authorization is false and ' \
                           'api_action_authorization / api_assignment_authorization is not set. ' \
                           'api_auth only proves identity — any authenticated caller can create ' \
                           'permission sets and assign them (privilege escalation). Configure both ' \
                           'authorization lambdas, or remove api_require_authorization = false ' \
                           '(the default, true, denies mutations until they are set).'
      end

      # One query for the distinct unmasked names (no record is built), and
      # one more for the resource of the first match.
      def warn_unmasked_gdpr_fields(config)
        patterns = config.gdpr_field_patterns
        return if patterns.blank?

        unmasked = PermissionForge::ResourceField.where(mask_access: false)
        name = unmasked.distinct.pluck(:name).find { |field_name| gdpr_match?(field_name, patterns) }
        return unless name

        resource = unmasked.where(name: name).first&.resource
        Rails.logger.warn "[PermissionForge] GDPR warning: field '#{name}' on resource " \
                          "'#{resource&.name}' matches GDPR pattern but is not masked. " \
                          'Consider enabling gdpr_defaults or masking this field manually.'
      rescue ActiveRecord::StatementInvalid
        # Table doesn't exist yet (pre-migration)
      end

      private

      # Connects and pings. `ActiveRecord::Base.connection` alone is not enough:
      # since Rails 7.2 it hands back a connection that has not connected yet,
      # so an unreachable database looked available.
      def db_available?
        PermissionForge::PermissionSet.connection_pool.with_connection(&:verify!)
        true
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def database_step(name)
        yield
      rescue *DATABASE_STEP_ERRORS => e
        Rails.logger&.warn "[PermissionForge] Boot check #{name} skipped: the database could not be read (#{e.class})."
      end

      # The boot step did not run: the first request or job that reaches the
      # database applies auto-applied masking (MaskingSync).
      def database_unreachable
        MaskingSync.reset!
        Rails.logger&.warn '[PermissionForge] The database could not be reached at boot; the boot checks that ' \
                           'read it (security warnings) were skipped. Auto-applied masking is applied at the first ' \
                           'request or job that reaches the database.'
      end

      # The boot warnings that only read the configuration.
      def warn_configuration(config)
        CacheWarnings.warn_process_local_cache(config)
        warn_basic_auth_without_credentials(config)
        warn_api_authorization_gap(config)
        config.tenantless_admin_warning&.then { |message| Rails.logger&.warn(message) }
        QueryScopingWarnings.warn_unscoped_detection_raise_in_production(config)
      end

      def warn_basic_auth_without_credentials(config)
        return unless config.http_basic_auth_enabled
        return if config.http_basic_auth_user.present? && config.http_basic_auth_password.present?

        Rails.logger&.warn '[PermissionForge] HTTP Basic Auth is enabled but credentials are not configured. ' \
                           'The admin UI will return 401 for all requests. ' \
                           'Set config.http_basic_auth_user and config.http_basic_auth_password.'
      end

      def gdpr_match?(field_name, patterns)
        patterns.any? { |regex, _| field_name.match?(regex) }
      end

      # Taken as the per-read selection takes it: a Hash, or anything with
      # #to_h (a Struct; nil is blank). A resolver that raises gives none.
      def resolved_context(config)
        resolved = config.request_context_resolver.call
        resolved.is_a?(Hash) ? resolved : resolved.to_h
      rescue StandardError
        {}
      end
    end
  end
end
