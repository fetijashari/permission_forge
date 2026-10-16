# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options that only affect the built-in admin UI (never permission checks).
    #
    # @api public
    module AdminUiSettings
      # The default of admin_stale_assignment_days, and the threshold used
      # wherever that setting is nil (the one definition of the fallback).
      DEFAULT_STALE_ASSIGNMENT_DAYS = 90

      # Lambda returning the model classes offered in "Add a resource".
      # nil (default) eager-loads app/models and lists every concrete
      # ActiveRecord model with a table, excluding PermissionForge's own.
      #   config.admin_model_resolver = -> { [Customer, Invoice, Deal] }
      attr_accessor :admin_model_resolver

      # Friendly labels for the session flags offered on the Conditions tab.
      # Keys are the flag names your request_context_resolver puts in
      # :session_flags. Flags already used by a Permission Set are always shown.
      #   config.admin_session_flags = { 'mfa_verified' => 'Signed in with two-factor' }
      attr_accessor :admin_session_flags

      # Assignments not reviewed for this many days appear under
      # "Stale assignments" on the admin home page; also the default threshold
      # of StaleAssignmentAuditor and rake permission_forge:stale_assignments. Default: 90
      # (DEFAULT_STALE_ASSIGNMENT_DAYS, also used when it is set to nil).
      attr_accessor :admin_stale_assignment_days

      # Name of the host app shown under the logo (e.g. "Acme CRM").
      # nil (default) derives it from the Rails application class.
      attr_accessor :admin_app_name

      # Where the "Back to <app>" link under the logo points. A String, or a
      # lambda receiving the view context (e.g. ->(view) { view.main_app.dashboard_path }).
      # nil (default) uses the host app's root route, or "/".
      attr_accessor :admin_back_url

      # Base URL for "Configuration docs" links on the Settings page. The
      # setting key is appended as an anchor.
      attr_accessor :admin_docs_url

      # What the admin screens and the admin JSON API do with a request that
      # has no current tenant while tenancy is on (tenant_model):
      #
      #   :deny  — refuse it with a 403, recorded as admin.auth_failed /
      #            api.auth_failed, reason tenant_missing (default). With no
      #            tenant acts_as_tenant scopes nothing, so the request would
      #            read and change every tenant's permissions.
      #   :allow — serve it: it reads, edits and deletes existing records of
      #            every tenant. Creating a record still needs a tenant (the
      #            new row's tenant is required): with none, a create is
      #            refused as invalid ("must exist"), never stored tenant-less.
      #
      # A String is taken as its Symbol; any other value raises
      # ConfigurationError (StrategyValues). Set the tenant in the controllers
      # the engine inherits from (base_controller_class, api_base_controller_class)
      # or in middleware.
      attr_accessor :admin_tenantless_access

      # Whether an API-only application (`config.api_only = true`) that
      # mounts the engine is warned that the admin screens need the cookies,
      # session and flash middlewares (default true). false for an app that
      # uses only the JSON API and never opens the admin screens.
      attr_accessor :api_only_admin_warning

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_admin_ui_defaults
        @admin_model_resolver = nil
        @admin_session_flags = {}
        @admin_stale_assignment_days = DEFAULT_STALE_ASSIGNMENT_DAYS
        @admin_app_name = nil
        @admin_back_url = nil
        @admin_docs_url = 'https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md'
        @admin_tenantless_access = :deny
        @api_only_admin_warning = true
      end

      # @return [Boolean] whether an admin or admin API request may run with
      #   no current tenant. Only the exact :allow value allows.
      def admin_tenantless_access_allowed?
        admin_tenantless_access.to_s == 'allow'
      end

      # The admin base-controller settings still at the default
      # ::ActionController::Base while tenancy is on: nothing the engine
      # inherits from sets the tenant there (the API's only counts when the
      # API is enabled).
      #
      # @return [Array<Symbol>] e.g. [:base_controller_class]
      def default_admin_controllers_under_tenancy
        return [] unless tenant_enabled?

        names = { base_controller_class: base_controller_class }
        names[:api_base_controller_class] = api_base_controller_class if api_enabled
        names.select { |_, name| name.to_s.delete_prefix('::') == 'ActionController::Base' }.keys
      end

      # The boot warning for default_admin_controllers_under_tenancy, or nil.
      #
      # @return [String, nil]
      def tenantless_admin_warning
        names = default_admin_controllers_under_tenancy
        return if names.empty?

        consequence = if admin_tenantless_access_allowed?
                        'admin_tenantless_access is :allow, so a request with no tenant reads and changes the ' \
                          'existing records of every tenant.'
                      else
                        'Every admin request with no tenant is refused (admin_tenantless_access :deny).'
                      end
        '[PermissionForge] SECURITY warning: tenant_model is set but ActionController::Base, which sets no ' \
          "tenant, is still the base of #{names.join(' and ')}. #{consequence} Point each at a controller " \
          'that sets the current tenant (or set the tenant in middleware).'
      end
    end
  end
end
