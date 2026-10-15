require_relative 'query_scoping_warnings'
require_relative 'cache_warnings'
require_relative 'boot_checks'
require_relative 'masking_sync'
require_relative 'masked_models'

module PermissionForge
  # Wires the gem into the host application: initializers, the executor and
  # reloader hooks, the boot checks. The work is done by plain modules
  # (BootChecks, MaskingSync, Audit, ...).
  #
  # @api public
  class Engine < ::Rails::Engine
    isolate_namespace PermissionForge

    config.generators do |g|
      g.test_framework :minitest
    end

    # A denial nobody rescues answers 403, not 500: the row-rule refusal of
    # find_by / find_by! and the action guard's refusal (Rails' exceptions
    # app renders the status: public/403.html when the host has one, else an
    # empty body). A host's rescue_from runs first and still decides.
    #
    # Set as the gem loads, as ActiveRecord's railtie sets its own: before
    # ActionDispatch copies the setting into ExceptionWrapper, and before the
    # host's config/application.rb, whose entry for either name wins. Class
    # names, not constants: nothing is loaded for this.
    config.action_dispatch.rescue_responses.merge!(
      'PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError' => :forbidden,
      'PermissionForge::ActionNotAuthorizedError' => :forbidden,
      # A request value the admin cannot read (ParamShapes::InvalidParam, an
      # ActionController::BadRequest): 400 as its parent, which Rails maps by
      # exact class name only. The API answers it with a 422 itself.
      'PermissionForge::ParamShapes::InvalidParam' => :bad_request
    )

    # The models (app/models/permission_forge) are autoloaded like any engine
    # model: their class bodies read the configuration after the host's
    # config/initializers, so nothing is re-declared after boot. No engine
    # initializer may reference them — the application's autoloader is set up
    # after every initializer has run (Rails 7.1+).

    # The admin UI's CSS/JS/brand files are served by PermissionForge::AssetsController
    # straight from app/frontend — no Sprockets/Propshaft/importmap registration needed.

    initializer 'permission_forge.i18n' do
      locale_dir = root.join('config', 'locales')
      allowed = PermissionForge.configuration.available_locales || PermissionForge::BUNDLED_LOCALES

      if allowed.present?
        pattern = "{#{Array(allowed).join(',')}}"
        config.i18n.load_path += Dir[locale_dir.join("permission_forge.#{pattern}.yml")]
      else
        config.i18n.load_path += Dir[locale_dir.join('permission_forge.*.yml')]
      end
    end

    initializer 'permission_forge.append_routes' do |_app|
      # Routes are only active when the engine is mounted — no automatic injection
    end

    initializer 'permission_forge.filter_parameters', after: :load_config_initializers do |app|
      pf_config = PermissionForge.configuration
      if pf_config.gdpr_defaults && pf_config.filter_parameters_integration
        new_filters = PermissionForge.gdpr_filter_parameters
        app.config.filter_parameters += new_filters

        # Not while a generator boots the app (BootChecks): the install
        # generator's boot predates the initializer it writes.
        unless PermissionForge::BootChecks.generator_running?
          Rails.logger.info "[PermissionForge] Added #{new_filters.size} GDPR patterns to filter_parameters."
        end
      end
    end

    # Tenancy needs the acts_as_tenant gem: refuse to boot without it. The
    # scope itself is declared by each model as it loads (HasTenantScoping).
    initializer 'permission_forge.tenant_scoping', after: :load_config_initializers do
      PermissionForge::BootChecks.ensure_tenancy_gem!(PermissionForge.configuration)
    end

    # Audit event log: install the notification subscribers (Audit::Subscribers
    # — log, store and legacy-hook adapters register there) and reset the
    # audit context at the end of every executor run.
    initializer 'permission_forge.audit', after: :load_config_initializers do |app|
      PermissionForge::Audit.install!(app)
      PermissionForge::Audit::JobContext.install!
    end

    # Level 2 — install the unscoped-query detection subscriber once config is
    # final. The per-event check re-reads config, so the subscriber is only
    # installed when detection could ever be active (avoids a no-op subscriber
    # on every query in production).
    initializer 'permission_forge.unscoped_query_detection', after: :load_config_initializers do
      PermissionForge::Services::UnscopedQueryDetector.install! if PermissionForge.configuration.unscoped_query_detection != :off
    end

    # Auto-applied masking in every process (MaskingSync): a check at the
    # start of each request and job, and a re-apply after a code reload.
    # Installed whatever the settings say now: one may be switched on after
    # the boot step (check! costs nothing while both are off).
    initializer 'permission_forge.masking_sync' do |app|
      app.executor.to_run { PermissionForge::MaskingSync.check! }
    end

    config.to_prepare { PermissionForge::MaskingSync.reloaded! }

    config.after_initialize do
      PermissionForge::BootChecks.run(PermissionForge.configuration)
    end

    # A setting a model reads as it loads (user_class, audit_user_class,
    # tenant_model) changed by the host's own after_initialize, once a
    # production boot has eager-loaded the models: the classes keep what they
    # declared (a development process would pick the change up). Registered
    # after config/initializers so it runs after the after_initialize blocks
    # declared there; nothing loads a model.
    initializer 'permission_forge.model_bindings', after: :load_config_initializers do |app|
      app.config.after_initialize { PermissionForge::ModelBindings.warn! }
    end

    # Deprecated: the masking machinery left the Engine (0.14). Removed in
    # PermissionForge::Deprecation::HORIZON.
    #
    # @return [Boolean] what MaskedModels.apply returns
    def self.apply_masked_attributes_to_managed_models(only: nil)
      PermissionForge::Deprecation.warn(
        'PermissionForge::Engine.apply_masked_attributes_to_managed_models is deprecated; ' \
        'use PermissionForge::MaskedModels.apply(only:)',
        callstack: caller_locations(1) # the host's call, not this method
      )
      PermissionForge::MaskedModels.apply(only: only)
    end
  end
end
