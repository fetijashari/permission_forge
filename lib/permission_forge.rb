require 'active_support'
require 'active_record'

require_relative 'permission_forge/version'
require_relative 'permission_forge/deprecation'
require_relative 'permission_forge/configuration/gdpr_settings'
require_relative 'permission_forge/configuration/masked_attributes_settings'
require_relative 'permission_forge/configuration/permits_attributes_settings'
require_relative 'permission_forge/configuration/query_scoping_settings'
require_relative 'permission_forge/configuration/admin_ui_settings'
require_relative 'permission_forge/configuration/virtual_attributes_settings'
require_relative 'permission_forge/configuration/controller_action_settings'
require_relative 'permission_forge/configuration/cache_settings'
require_relative 'permission_forge/configuration/audit_settings'
require_relative 'permission_forge/configuration/strategy_values'
require_relative 'permission_forge/configuration/presets'
require_relative 'permission_forge/configuration'

# Entry point of the gem: configuration, the current user, the cache and the table prefix.
#
# @example
#   PermissionForge.configure do |config|
#     config.current_user_resolver = -> { Current.user }
#   end
#
# @api public
module PermissionForge
  # Raised by Level 2 detection (config.unscoped_query_detection = :raise) when
  # a protected model is queried outside a permission-scoped path.
  #
  # @api public
  class UnscopedQueryError < StandardError; end

  # Raised by Concerns::ControllerActionGuard when the current user may not run
  # the requested controller action. The guard never renders — rescue this in
  # the host app (rescue_from) and answer 403.
  #
  # `reason` is the Authorizer's reason symbol, so a handler can tell "nobody
  # is signed in" (:nil_user_denied — send to login) from a real denial.
  #
  # @api public
  class ActionNotAuthorizedError < StandardError
    # user: who was refused (nil for no user); record: the record the action
    # was about, when the caller knows it (the guard runs before the action
    # loads one, so it passes none).
    attr_reader :resource, :action, :controller_path, :reason, :user, :record

    def initialize(resource:, action:, controller_path:, reason: nil, user: nil, record: nil) # rubocop:disable Metrics/ParameterLists
      @resource = resource
      @action = action
      @controller_path = controller_path
      @reason = reason
      @user = user
      @record = record
      super("Not authorized to run '#{action}' on #{resource} (#{controller_path})")
    end
  end

  # Locales the gem ships translation files for. Used as the fallback when
  # config.available_locales is not set, so the admin UI never reflects
  # locales registered by the host app (e.g. Faker) that PermissionForge
  # has no translations for.
  BUNDLED_LOCALES = %i[en sq mk].freeze

  # A Resource name (Resource#name, a controller's declared resource): a Ruby
  # constant path. The one definition — Resource::NAME_FORMAT and
  # ControllerActions::RESOURCE_FORMAT point here.
  RESOURCE_NAME_FORMAT = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/

  # The ActiveRecord models, in app/models/permission_forge. They are
  # autoloaded (and in development reloaded) by the host application, not
  # required by the gem, so a class body reads the configuration — the user
  # class of an assignment, the audit user class, the tenant model — after the
  # host's config/initializers have run, and there is nothing to rebind.
  MODEL_NAMES = %i[
    PermissionSet PermissionSetUser PermissionSetGroup PermissionSetGroupUser
    Resource ResourceField ResourceAction PermissionSetRule AuditEvent
  ].freeze

  # ExecutionState slot (fiber-local): when truthy, Level 1 auto-scoping and
  # Level 2 detection are suspended for the running fiber. Set via
  # without_permission_scope.
  SKIP_SCOPE_KEY = :pf_skip_auto_scope

  # Guards @permissions_cache_version increments; reads are lock-free.
  PERMISSIONS_CACHE_VERSION_MUTEX = Mutex.new

  class << self
    # The models can only be resolved once the Rails application has set up
    # its autoloader, which happens after every file in config/initializers
    # has run (Rails 7.1+). Before that — the top level of an initializer, or
    # no Rails application at all — say what to do instead of "uninitialized
    # constant". Zeitwerk registers the autoloads itself, so this is never
    # reached for a model name after boot.
    def const_missing(name)
      return super unless MODEL_NAMES.include?(name)

      raise NameError.new(
        "PermissionForge::#{name} is autoloaded by the Rails application once it has booted, so it cannot be " \
        'referenced before that: not from the top level of a file in config/initializers, an engine or railtie ' \
        'initializer or a file required from config/application.rb, nor outside a Rails application. Reference ' \
        'it from a method (a model, a controller, a job, a rake task). To change the class — include a module, ' \
        'add a callback — use Rails.application.config.to_prepare or ' \
        "Rails.autoloaders.main.on_load('PermissionForge::#{name}'), which run again after every code reload; " \
        'config.after_initialize runs once, so use it only to read.',
        name
      )
    end

    # @return [Configuration] the settings, created on first use
    def configuration
      @configuration ||= Configuration.new
    end

    # Configure in config/initializers: the models read the configuration as
    # they load, right after. A setting a loaded model took is compared
    # afterwards and a difference logged (ModelBindings).
    def configure
      yield(configuration)
      configuration.reset_cache_store!
      ModelBindings.warn!(configuration)
    end

    # Replaces the configuration with a fresh default one (tests and console).
    # @return [void]
    def reset!
      @configuration = Configuration.new
      bump_permissions_cache_version!
    end

    # Process-local generation counter for cached permission hashes. Instances
    # memoize their permissions_hash keyed by this value; bumping it (on any
    # invalidation, regeneration, or cache-store swap) makes every memo in the
    # process re-read from the cache store on next access. Cross-process
    # coherence is unchanged — it still comes from the shared cache store.
    def permissions_cache_version
      @permissions_cache_version || 0
    end

    # Retires every per-instance `permissions_hash` memo (they compare against this version).
    # Called by `invalidate_permissions`, `regenerate_permissions` and a cache-store swap.
    # @return [Integer] the new version
    # @api private
    def bump_permissions_cache_version!
      PERMISSIONS_CACHE_VERSION_MUTEX.synchronize do
        @permissions_cache_version = permissions_cache_version + 1
      end
    end

    # @return [Object, nil] whatever `config.current_user_resolver` answers
    def current_user
      configuration.current_user_resolver.call
    end

    # @return [Cache::Base] the permission cache store (`config.cache_store`)
    def cache
      configuration.cache_store
    end

    # Id of the tenant acts_as_tenant has made ambient, when tenancy is on:
    # the tenant a permission hash is built and cached for.
    def ambient_tenant_id
      return unless configuration.tenant_enabled? && defined?(ActsAsTenant)

      ActsAsTenant.current_tenant&.id
    end

    # The tenant acts_as_tenant has made ambient (nil: none, or tenancy is off).
    # Together with with_ambient_tenant it carries a request's tenant into work
    # that runs after the request's own wrappers have ended (a streamed body).
    def ambient_tenant
      return unless configuration.tenant_enabled? && defined?(ActsAsTenant)

      ActsAsTenant.current_tenant
    end

    # Runs the block with `tenant` ambient. Does nothing when there is none to
    # pin, or it is the ambient one already. Restores the request-level tenant
    # as it was (not acts_as_tenant's with_tenant, which writes the tenant it
    # resolved — test or default included — back into ActsAsTenant::Current).
    def with_ambient_tenant(tenant)
      return yield unless tenant && configuration.tenant_enabled? && defined?(ActsAsTenant)
      return yield if ActsAsTenant.current_tenant == tenant

      previous = ActsAsTenant::Current.current_tenant
      ActsAsTenant.current_tenant = tenant
      begin
        yield
      ensure
        ActsAsTenant::Current.current_tenant = previous
      end
    end

    # @return [String] the table prefix, `permission_forge_` unless configured
    def table_name_prefix
      configuration.table_name_prefix
    end

    # Escape hatch for intentional unscoped access (admin panels, reports,
    # background maintenance). Inside the block, Level 1 auto-scoping and
    # Level 2 detection are suspended on the running fiber (not in another
    # fiber, an Enumerator's included: ExecutionState), and with nobody
    # signed in find_by, find_by! and permission_scoped apply no rules,
    # whatever nil_user_strategy says (rule.bypassed, scope_suspended); a
    # signed-in user's find_by and permission_scoped still apply theirs. So
    # inside the block nobody signed in is trusted more than a signed-in
    # user: wrap trusted code only (jobs, seeds, rake tasks, sign-in lookups),
    # never code an anonymous request reaches.
    # Nesting-safe: restores the previous flag value on exit.
    #
    #   PermissionForge.without_permission_scope { Customer.where(...) }
    def without_permission_scope(&)
      ExecutionState.with(SKIP_SCOPE_KEY, true, &)
    end

    # @return [Boolean] whether permission scoping is currently suspended on
    #   this thread (internal builds and without_permission_scope blocks).
    def scope_suspended?
      !!ExecutionState[SKIP_SCOPE_KEY]
    end

    # Names who acts for every audit event recorded inside the block — a job,
    # a rake task, a service run on someone's behalf — and where it comes
    # from. Wins over the request context and PermissionForge.current_user.
    #
    #   PermissionForge.with_audit_actor(user: admin, source: 'job') { cleaner.call }
    #   PermissionForge.with_audit_actor(label: ENV['ACTOR'], source: 'rake', reason: 'TCK-12') { ... }
    #
    # @param user [Object, nil] the acting user (actor_type 'user' unless type: says otherwise)
    # @param label [String, nil] the name recorded; required without a user
    # @param type [String, nil] user, api, basic_auth, system (default: 'user'
    #   with a user, 'system' without)
    # @param source [String, nil] admin_ui, api, rake, job, console, service, runtime
    # @param reason [String, nil] stored on every event of the block
    # @return the value of the block
    def with_audit_actor(user: nil, label: nil, type: nil, source: nil, reason: nil, &)
      actor = if user
                Audit::Actor.for_user(user, label: label, type: type || 'user')
              elsif label || type
                Audit::Actor.new(type: type || 'system', label: label)
              end
      Audit::Context.with(actor: actor, source: source, reason: reason, &)
    end

    # Returns an array of regexes derived from the configured GDPR field patterns,
    # suitable for appending to Rails.application.config.filter_parameters.
    #
    # Usage (manual):
    #   Rails.application.config.filter_parameters += PermissionForge.gdpr_filter_parameters
    #
    # Or set config.filter_parameters_integration = true for automatic injection.
    def gdpr_filter_parameters
      return [] unless configuration.gdpr_defaults

      configuration.gdpr_field_patterns.keys
    end
  end
end

require_relative 'permission_forge/execution_state'
require_relative 'permission_forge/inspection_filters'
require_relative 'permission_forge/model_bindings'
require_relative 'permission_forge/cache/base'
require_relative 'permission_forge/cache/memory_cache'
require_relative 'permission_forge/cache/null_cache'
require_relative 'permission_forge/cache/handled_errors'
require_relative 'permission_forge/cache/rails_cache'
require_relative 'permission_forge/cache/failure'
require_relative 'permission_forge/cache/backlog'
require_relative 'permission_forge/cache/invalidation'
require_relative 'permission_forge/cache/bulk_invalidation'
require_relative 'permission_forge/cache/user_keys'
require_relative 'permission_forge/cache/holder_invalidation'
require_relative 'permission_forge/cache/variant_removal'
require_relative 'permission_forge/cache/withheld_notice'
require_relative 'permission_forge/cache/rebuild'
require_relative 'permission_forge/open_transaction'
require_relative 'permission_forge/cache/settlement'

# Audit event log
require_relative 'permission_forge/audit/event_catalog'
require_relative 'permission_forge/audit/actor'
require_relative 'permission_forge/audit/source'
require_relative 'permission_forge/audit/context'
require_relative 'permission_forge/audit/failure'
require_relative 'permission_forge/audit/column_values'
require_relative 'permission_forge/audit/recorder'
require_relative 'permission_forge/audit/subscribers'
require_relative 'permission_forge/audit/log_access'
require_relative 'permission_forge/audit/event_query'
require_relative 'permission_forge/audit/runtime_emission'
require_relative 'permission_forge/audit'
require_relative 'permission_forge/audit/gate'
require_relative 'permission_forge/audit/runtime'
require_relative 'permission_forge/audit/field_access'
require_relative 'permission_forge/audit/subscribers/base'
require_relative 'permission_forge/audit/subscribers/legacy_hooks'
require_relative 'permission_forge/audit/subscribers/log'
require_relative 'permission_forge/audit/actor_resolver'
require_relative 'permission_forge/audit/audited_views'
require_relative 'permission_forge/audit/request_context'
require_relative 'permission_forge/audit/detached'
require_relative 'permission_forge/audit/refusals'
require_relative 'permission_forge/audit/job_context'
require_relative 'permission_forge/audit/settings_observer'
require_relative 'permission_forge/audit/boot_warnings'

require_relative 'permission_forge/resource_chain'
require_relative 'permission_forge/virtual_fields'
require_relative 'permission_forge/virtual_fields/discovery'
require_relative 'permission_forge/field_variants'
require_relative 'permission_forge/field_names'
require_relative 'permission_forge/timestamp_fields'

require_relative 'permission_forge/concerns/has_active_scope'
require_relative 'permission_forge/concerns/has_tenant_scoping'
require_relative 'permission_forge/concerns/has_uuid'
require_relative 'permission_forge/concerns/has_audit_trail'
require_relative 'permission_forge/invalidation_batch'
require_relative 'permission_forge/concerns/invalidates_in_batch'
require_relative 'permission_forge/concerns/has_permission_set_users'
require_relative 'permission_forge/concerns/validates_dependency'
require_relative 'permission_forge/concerns/validates_column_lengths'
require_relative 'permission_forge/concerns/permissions_regenerator'
require_relative 'permission_forge/concerns/invalidates_managed_actions'
require_relative 'permission_forge/concerns/records_audit_events'
require_relative 'permission_forge/concerns/audited_collection'
require_relative 'permission_forge/conditional_sets'
require_relative 'permission_forge/concerns/permissions_memo'
require_relative 'permission_forge/concerns/permissions_per_context'
require_relative 'permission_forge/concerns/permission_cache_accessor'
require_relative 'permission_forge/concerns/resource_permission_checker'
require_relative 'permission_forge/concerns/field_mask_checker'
require_relative 'permission_forge/concerns/permissioned_user'
require_relative 'permission_forge/concerns/auto_permission_scoping'
require_relative 'permission_forge/concerns/permission_scoped_findable'
require_relative 'permission_forge/concerns/masked_attributes'

require_relative 'permission_forge/operators/constants'
require_relative 'permission_forge/operators/validations'
require_relative 'permission_forge/operators/value_casters'
require_relative 'permission_forge/operators/rule_column'
require_relative 'permission_forge/operators/value_typing'
require_relative 'permission_forge/services/mask_value'

# The models are not required here: they live in app/models/permission_forge
# and are autoloaded by the host application (see MODEL_NAMES above), so
# their class bodies read the configuration after config/initializers.

require_relative 'permission_forge/operators/registry'

require_relative 'permission_forge/controller_actions'
require_relative 'permission_forge/controller_actions/mapping'
require_relative 'permission_forge/controller_actions/managed_index'
require_relative 'permission_forge/controller_actions/authorizer'
require_relative 'permission_forge/concerns/controller_action_guard'

require_relative 'permission_forge/api/serializers/base_serializer'
require_relative 'permission_forge/api/serializers/permission_set_serializer'
require_relative 'permission_forge/api/serializers/resource_serializer'
require_relative 'permission_forge/api/serializers/resource_field_serializer'
require_relative 'permission_forge/api/serializers/resource_action_serializer'
require_relative 'permission_forge/api/serializers/permission_set_rule_serializer'
require_relative 'permission_forge/api/serializers/permission_set_user_serializer'
require_relative 'permission_forge/api/serializers/audit_event_serializer'
require_relative 'permission_forge/api/serializers/permission_set_group_serializer'
require_relative 'permission_forge/api/serializers/permission_set_group_user_serializer'

require_relative 'permission_forge/services/concerns/clonable'
require_relative 'permission_forge/services/concerns/audited_operation'
require_relative 'permission_forge/services/concerns/across_tenants'
require_relative 'permission_forge/services/bulk_permission_set_assignment'
require_relative 'permission_forge/services/consent_withdrawal_handler'
require_relative 'permission_forge/services/expired_assignment_cleaner'
require_relative 'permission_forge/services/permission_cache_clearer'
require_relative 'permission_forge/services/permission_set_condition_evaluator'
require_relative 'permission_forge/services/permission_set_cloner'
require_relative 'permission_forge/services/permission_set_group_cloner'
require_relative 'permission_forge/services/permission_rule_applier'
require_relative 'permission_forge/services/resource_with_fields_builder'
require_relative 'permission_forge/services/dashboard_stats'
require_relative 'permission_forge/services/extra_field_defaults'
require_relative 'permission_forge/services/field_permission_merger'
require_relative 'permission_forge/services/filters_response_attributes'
require_relative 'permission_forge/services/attribute_access_guard'
require_relative 'permission_forge/services/gdpr_field_auditor'
require_relative 'permission_forge/services/permission_hash_builder'
require_relative 'permission_forge/services/permits_attributes'
require_relative 'permission_forge/services/permits_attributes/nested_records'
require_relative 'permission_forge/services/permits_attributes/result'
require_relative 'permission_forge/services/data_subject_erasure'
require_relative 'permission_forge/services/host_key_guard'
require_relative 'permission_forge/services/stale_assignment_auditor'
require_relative 'permission_forge/services/audit_event_purger'
require_relative 'permission_forge/rake_audit'
require_relative 'permission_forge/services/resource_field_generator'
require_relative 'permission_forge/services/unscoped_query_detector'
require_relative 'permission_forge/services/rls_operator_sql'
require_relative 'permission_forge/services/rls_policy_generator'
require_relative 'permission_forge/rls'

# Admin UI support (read models + batched edits for the built-in admin screens)
require_relative 'permission_forge/admin/field_level'
require_relative 'permission_forge/admin/sensitive_columns'
require_relative 'permission_forge/admin/model_catalog'
require_relative 'permission_forge/admin/person_label'
require_relative 'permission_forge/admin/people_candidates'
require_relative 'permission_forge/admin/people_directory'
require_relative 'permission_forge/admin/record_id'
require_relative 'permission_forge/admin/editable_lock'
require_relative 'permission_forge/admin/expiry_presets'
require_relative 'permission_forge/admin/effective_access'
require_relative 'permission_forge/admin/effective_fields'
require_relative 'permission_forge/admin/settings_values'
require_relative 'permission_forge/admin/settings_catalog'
require_relative 'permission_forge/admin/csv'
require_relative 'permission_forge/admin/last_changes'
require_relative 'permission_forge/admin/audit_trail'
require_relative 'permission_forge/admin/audit_log_days'
require_relative 'permission_forge/admin/audit_log'
require_relative 'permission_forge/admin/audit_name_history'
require_relative 'permission_forge/admin/audit_lookups'
require_relative 'permission_forge/admin/exports'
require_relative 'permission_forge/admin/exports/document'
require_relative 'permission_forge/admin/exports/events'
require_relative 'permission_forge/admin/exports/holdings'
require_relative 'permission_forge/admin/attention_items'
require_relative 'permission_forge/admin/change_set_parts/context'
require_relative 'permission_forge/admin/change_set_parts/values'
require_relative 'permission_forge/admin/change_set_parts/base'
require_relative 'permission_forge/admin/change_set_parts/set_attrs'
require_relative 'permission_forge/admin/change_set_parts/resource_edit'
require_relative 'permission_forge/admin/change_set_parts/resource_flags'
require_relative 'permission_forge/admin/change_set_parts/field_edit'
require_relative 'permission_forge/admin/change_set_parts/field_levels'
require_relative 'permission_forge/admin/change_set_parts/new_fields'
require_relative 'permission_forge/admin/change_set_parts/actions'
require_relative 'permission_forge/admin/change_set_parts/new_actions'
require_relative 'permission_forge/admin/change_set'
require_relative 'permission_forge/admin/field_rows'
require_relative 'permission_forge/admin/field_detail'
require_relative 'permission_forge/admin/audit_event_detail'
require_relative 'permission_forge/admin/rule_builder'
require_relative 'permission_forge/admin/field_across_sets'
require_relative 'permission_forge/admin/controller_catalog'
require_relative 'permission_forge/admin/action_across_sets'
require_relative 'permission_forge/admin/action_rows'
require_relative 'permission_forge/admin/column_fields'
require_relative 'permission_forge/admin/conditions_form'
require_relative 'permission_forge/admin/permission_set_factory'
require_relative 'permission_forge/admin/rule_form_input'
require_relative 'permission_forge/admin/rule_form'
require_relative 'permission_forge/admin/bulk_people_matcher'

# Security review (rake permission_forge:audit)
require_relative 'permission_forge/services/security_audit'
require_relative 'permission_forge/services/security_audit/base_check'
require_relative 'permission_forge/services/security_audit/config_check'
require_relative 'permission_forge/services/security_audit/privilege_check'
require_relative 'permission_forge/services/security_audit/assignment_check'
require_relative 'permission_forge/services/security_audit/rule_check'
require_relative 'permission_forge/services/security_audit/integrity_check'
require_relative 'permission_forge/services/security_audit/personal_data_check'
require_relative 'permission_forge/services/security_audit/action_check'
require_relative 'permission_forge/services/security_audit/audit_trail_check'
require_relative 'permission_forge/services/security_audit/user_model_check'
require_relative 'permission_forge/services/security_audit/text_report'

require_relative 'permission_forge/engine' if defined?(Rails::Engine)
