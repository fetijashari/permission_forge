# frozen_string_literal: true

require_relative 'warnings'
require_relative 'api_only_admin'
require_relative 'database_reach'
require_relative 'api_authorizations'

module PermissionForge
  # What the engine checks while the host app boots: run (from
  # config.after_initialize) and ensure_tenancy_gem! (from an initializer).
  #
  # The configuration checks need nothing. The database steps are advisory
  # warnings or idempotent work, and they must never abort a boot: a Docker
  # build precompiles assets with no database, a fresh `rails new
  # --skip-kamal` app has no production database file until the deploy sets
  # DATABASE_URL, a worker can start while the database fails over. The
  # database is pinged once (DatabaseReach.problem: whatever connecting
  # raises, an adapter's refusal of its configuration included); a step that
  # loses it midway is skipped (DATABASE_STEP_ERRORS) and the next step runs.
  # Anything else a step raises (a ConfigurationError) still stops the boot.
  #
  # A process that runs nothing but asset tasks (asset_build?:
  # `bin/rails assets:precompile`, the Dockerfile's build step) runs the
  # configuration checks only: it reads no data and serves nothing, and a
  # build has no database to ping (an unreachable host could hold the build
  # for a TCP timeout).
  #
  # Every warning goes through Warnings.emit, which decides the channel (the
  # log; the terminal where the log is not read) and writes nothing while a
  # generator boots the app (Warnings.generator_running?): `bin/rails
  # generate permission_forge:install` boots before it writes the
  # initializer, so its warnings described a configuration the app was about
  # to stop having (the defaults, e.g. cache_backend :memory) — the first
  # lines a new user read in log/development.log. Nothing is checked then
  # either (run returns before the database steps). The next server, console
  # or task boot checks the configuration the app has.
  #
  # @api private
  module BootChecks
    # Errors that mean "the database is not there (yet)" once it answered the
    # ping: gone, refused, not created, not migrated (DatabaseReach::READ_ERRORS).
    DATABASE_STEP_ERRORS = DatabaseReach::READ_ERRORS

    # The asset tasks of Propshaft and Sprockets (each boots the app through
    # :environment). A process whose Rake top-level tasks are all among them
    # is an asset build (asset_build?).
    ASSET_TASKS = %w[assets:precompile assets:clean assets:clobber].freeze

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

    # The commands `bin/rails generate` and `bin/rails destroy` run (the one
    # definition is the emitter's: Warnings::GENERATOR_COMMANDS).
    GENERATOR_COMMANDS = Warnings::GENERATOR_COMMANDS

    class << self
      # @param config [Configuration]
      def run(config)
        config.validate_gdpr_explicit_choice!
        return MaskingSync.reset! if generator_running?

        warn_configuration(config)
        return MaskingSync.reset! if asset_build?

        problem = database_problem
        return database_unreachable(problem) if problem

        DATABASE_STEPS.each { |name, step| database_step(name) { step.call(config) } }
      end

      # Whether this boot is that of a generator (`bin/rails generate` or
      # `bin/rails destroy`): Warnings.generator_running?, which also keeps
      # every warning quiet then.
      #
      # @return [Boolean]
      def generator_running?
        Warnings.generator_running?
      end

      # Whether this process runs nothing but asset tasks (ASSET_TASKS): the
      # tasks Rake was asked for on the command line (`bin/rails
      # assets:precompile`), not a task that only depends on one. False
      # outside Rake.
      #
      # @return [Boolean]
      def asset_build?
        return false unless defined?(::Rake.application)

        tasks = ::Rake.application.top_level_tasks.map { |task| task.sub(/\[.*\z/m, '') }
        tasks.any? && tasks.all? { |task| ASSET_TASKS.include?(task) }
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

        Warnings.emit(:conditional_sets_without_context,
                      "#{conditional_sets.count} permission set(s) use activation conditions " \
                      '(session flag, allowed_ips, or login hours) but request_context_resolver ' \
                      'returns empty context. These sets will evaluate as unconditional ' \
                      '(ALWAYS ACTIVE) — IP/hours/consent restrictions are NOT enforced. ' \
                      'Configure config.request_context_resolver, or set ' \
                      'config.conditional_sets_strict_mode = true to fail closed.', severity: :security)
      rescue ActiveRecord::StatementInvalid
        # Tables don't exist yet (pre-migration)
      end

      def warn_api_authorization_gap(config)
        return unless config.api_enabled
        return if config.api_require_authorization
        return if config.api_action_authorization && config.api_assignment_authorization

        Warnings.emit(:api_authorization_gap,
                      'API is enabled, config.api_require_authorization is false and ' \
                      'api_action_authorization / api_assignment_authorization is not set. ' \
                      'api_auth only proves identity — any authenticated caller can create ' \
                      'permission sets and assign them (privilege escalation). Configure both ' \
                      'authorization lambdas, or remove api_require_authorization = false ' \
                      '(the default, true, denies mutations until they are set).', severity: :security, audience: :server)
      end

      # The API is on and api_auth admits callers, but a lambda the API
      # needs is unset (ApiAuthorizations.unset): what it guards is refused
      # (403). It fails closed; the note says so before the first refused
      # request does. Under api_require_authorization = false the missing
      # change and assignment lambdas are api_authorization_gap's instead.
      #
      # @param config [Configuration]
      def warn_api_authorizations_unset(config)
        lines = ApiAuthorizations.lines(config)
        return if lines.empty?

        Warnings.emit(:api_authorization_unset,
                      'The JSON API is on and api_auth admits callers, but these authorization lambdas are not ' \
                      "set, so the API refuses (403, naming the option) what each guards — #{lines.join('; ')}. " \
                      'Set each one in config/initializers/permission_forge.rb (docs/admin-api.md#requiring-authorization-lambdas).',
                      audience: :server)
      end

      # One query for the distinct names of the rows in the clear that reach
      # someone's hash (in effect, in a granting set; no record is built),
      # and one more for the resource of the first match. What counts as
      # personal data is PermissionForge::SensitiveColumns' answer, as for
      # the GDPR audit and the admin.
      def warn_unmasked_gdpr_fields(config)
        sensitive = PermissionForge::SensitiveColumns.new(configuration: config)
        in_clear = PermissionForge::ResourceField.in_effect.merge(PermissionForge::PermissionSet.granting).exposing_unacknowledged
        name, match = first_sensitive(in_clear.distinct.pluck(:name), sensitive)
        return unless name

        resource = in_clear.where(name: name).first&.resource
        Warnings.emit(:unmasked_gdpr_fields,
                      "GDPR warning: field '#{name}' on resource '#{resource&.name}' #{matched_by(match)} " \
                      'but is not masked. Consider enabling gdpr_defaults or masking this field manually.')
      rescue ActiveRecord::StatementInvalid
        # Table doesn't exist yet (pre-migration)
      end

      # The admin screens in a `rails new --api` application: without the
      # cookies, session and flash middlewares every admin page that renders
      # a form is a 500 (ApiOnlyAdmin says which ones to add). Skipped when
      # config.api_only_admin_warning is false.
      #
      # @param application [Rails::Application]
      # @param config [Configuration]
      def warn_api_only_admin(application = Rails.application, config: PermissionForge.configuration)
        return unless config.api_only_admin_warning

        missing = ApiOnlyAdmin.missing_middlewares(application)
        return if missing.empty?

        Warnings.emit(:api_only_admin, ApiOnlyAdmin.message(missing), severity: :config, audience: :server)
      end

      # The engine's after_routes_loaded hook: the api_only_admin warning,
      # once per process (a development reload draws the routes again).
      #
      # @param application [Rails::Application]
      def routes_loaded(application)
        return if @routes_checked

        @routes_checked = true
        warn_api_only_admin(application)
      end

      private

      # [name, SensitiveColumns::Match] of the first name that looks like personal data.
      def first_sensitive(names, sensitive)
        names.lazy.filter_map { |name| (match = sensitive.match(name)) && [name, match] }.first
      end

      # What made the field personal data (SensitiveColumns::Match#source).
      def matched_by(match)
        match.filter_parameter? ? "is named by the application's filter_parameters" : "matches the GDPR pattern '#{match.pattern}'"
      end

      # What connecting to the gem's database raised, nil when it answered
      # (DatabaseReach.problem).
      #
      # @return [Exception, nil]
      def database_problem
        DatabaseReach.problem
      end

      def database_step(name)
        yield
      rescue *DATABASE_STEP_ERRORS => e
        Warnings.emit(:"boot_check_skipped.#{name}",
                      "Boot check #{name} skipped: the database could not be read (#{e.class}).")
      end

      # The boot step did not run: the first request or job that reaches the
      # database applies auto-applied masking (MaskingSync). The cause is
      # named: "not configured" (an adapter's ArgumentError) reads otherwise
      # than "refused". The ping loads the gem's models (and Active Record
      # with them, as Rails' lazy load would): an error raised there — a
      # host's on_load(:active_record) hook — is named the same way.
      def database_unreachable(problem)
        MaskingSync.reset!
        Warnings.emit(:database_unreachable,
                      "The database could not be reached at boot, or the gem's models could not be loaded " \
                      "(#{problem.class}: #{problem.message.lines.first&.strip}); " \
                      'the boot checks that read it (security warnings) were skipped. Auto-applied masking is ' \
                      'applied at the first request or job that reaches the database.')
      end

      # The boot warnings that only read the configuration.
      def warn_configuration(config)
        CacheWarnings.call(config)
        warn_basic_auth_without_credentials(config)
        warn_api_authorization_gap(config)
        warn_api_authorizations_unset(config)
        config.tenantless_admin_warning&.then { |message| warn_tenantless_admin(message) }
        QueryScopingWarnings.warn_unscoped_detection_raise_in_production(config)
      end

      # AdminUiSettings#tenantless_admin_warning is the text; the emitter
      # puts the prefix on.
      def warn_tenantless_admin(message)
        Warnings.emit(:tenantless_admin, message, severity: :security, audience: :server)
      end

      def warn_basic_auth_without_credentials(config)
        return unless config.http_basic_auth_enabled
        return if config.http_basic_auth_user.present? && config.http_basic_auth_password.present?

        Warnings.emit(:basic_auth_without_credentials,
                      'HTTP Basic Auth is enabled but credentials are not configured. The admin UI will return ' \
                      '401 for all requests. Set config.http_basic_auth_user and config.http_basic_auth_password.',
                      audience: :server)
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
