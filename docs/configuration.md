# Configuration

Before production, go through the Production hardening checklist in the README (https://github.com/fetijashari/permission_forge#production-hardening-checklist).

All configuration options with their defaults. These are the defaults of `PermissionForge::Configuration`; the initializer that `rails generate permission_forge:install` writes is short (the integration points, and the safe part of the hardening checklist: `action_guard_nil_user_strategy = :deny`, `conditional_sets_strict_mode = true`, `cache_backend = :rails_cache` and `masked_attributes_nil_user_strategy = :hide_in_requests`) and offers `config.preset = :strict` commented (see [Presets](#presets)). Every option it leaves out keeps the default shown here.

Set these in `config/initializers`. `user_class`, `audit_user_class` and `tenant_model` are read by the models as they load; a change made later does not reach a loaded class (PermissionForge logs a warning).

```ruby fragment
PermissionForge.configure do |config|
  # Sets the options that decide whether something fails open, all at once
  # (see Presets below: the options that need your code are not among them).
  # A setting made in this block wins over it, in any order.
  #   :compat — the defaults below (default)
  #   :strict — the closed values of the hardening checklist
  config.preset = :compat

  # User model class name (lazily constantized)
  config.user_class = 'User'

  # How to resolve the current user (must return user or nil). The generated
  # initializer sets
  #   -> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }
  # (works with or without a Current class). Until you wire it to your sign-in,
  # nobody is signed in and nil_user_strategy decides (with the default
  # :bypass, nothing is restricted).
  config.current_user_resolver = -> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }

  # How to check if a user is active. It does NOT remove access:
  # `rake permission_forge:audit` uses it to report assignments still held
  # by inactive users so you can revoke them (the Settings page shows it).
  config.user_active_check = ->(user) { user.respond_to?(:active_for_authentication?) ? user.active_for_authentication? : true }

  # People shown in the admin UI (People list, person pickers, group
  # member select), and the boundary of the people the admin UI and the API
  # can reach by id: anyone the resolver leaves out is not found (404).
  # Lists of a set's holders still show every holder.
  #
  # Default: user_model.order(:id) — schema-agnostic, because `:name` is
  # often a method (e.g. "#{first_name} #{last_name}") or virtual attribute
  # rather than a real column. A SQL ORDER BY :name would crash on those.
  #
  # Override the resolver to sort/scope however you want:
  #   config.user_list_resolver = -> { User.active.order(:last_name, :first_name) }
  #   config.user_list_resolver = -> { User.active.sort_by(&:name) }   # in-Ruby sort
  config.user_list_resolver = nil

  # Most people loaded into a picker before the admin asks for a search
  # (nil = no cap; not recommended for large tables).
  config.user_list_limit = 500

  # Label formatter for people in the admin UI.
  # Receives a user, returns a String shown to admins (the group member
  # select appends `#<id>` to keep labels unique).
  #
  # Default: tries name → full_name → display_name → composed
  # first_name/last_name (or firstname/lastname) → email (or email_address,
  # Rails 8's column) → `User #<id>`.
  # Override for full control:
  #   config.user_label_formatter = ->(u) { "#{u.last_name}, #{u.first_name} <#{u.email}>" }
  config.user_label_formatter = nil

  # Cache backend — works with ANY Rails cache store:
  #   :rails_cache  — uses Rails.cache (recommended for production)
  #   :memory       — in-memory hash (dev/test, no external deps)
  #   :null         — no caching
  #   Or pass an ActiveSupport::Cache::Store instance directly:
  #   ActiveSupport::Cache::RedisCacheStore.new(url: "redis://localhost:6379")
  #   ActiveSupport::Cache::SolidCacheStore.new(...)
  # Default: :memory. The generated initializer sets :rails_cache
  # (recommended for production). Use a store every process shares (Redis,
  # Memcached, Solid Cache). :memory is per process: an invalidation made in
  # one process does not reach the others, which keep the old hash until
  # cache_ttl. Under :memory or :null, masking auto-applied to a newly named
  # model reaches other processes only at their next boot (see "Deploying").
  config.cache_backend = :memory
  config.cache_key_prefix = 'pf'

  # Cache TTL in seconds for permission entries. Acts as a staleness backstop —
  # the cache is read-through, so expired entries are rebuilt transparently on
  # the next read and a TTL never leaves a user without permissions.
  # Set to nil for no expiration (not recommended).
  config.cache_ttl = 3600

  # TTL applied when any of the user's permission sets has activation conditions
  # (session flag, IP allowlist, login hours). The conditions are evaluated on
  # every read, against the request that reads; this clamps the base entry and
  # its per-context variants as a backstop. The effective TTL is
  # min(cache_ttl, conditional_set_cache_ttl), additionally clamped to the
  # soonest assignment expires_at. Set to nil to disable the clamp.
  config.conditional_set_cache_ttl = 300

  # Callback when the cache store fails an invalidation (it did not confirm
  # the stamp or a removal after the retries, an entry could not be removed,
  # or an after_commit invalidation raised). Nothing is raised; the failure is
  # logged at error level and published as the
  # `cache_failure.permission_forge` notification. The process that failed
  # makes the invalidation once the store answers again; until then — and in
  # other processes — cached permissions may be out of date until cache_ttl.
  # Errors of the hook are swallowed.
  config.on_cache_failure = nil
  # config.on_cache_failure = ->(operation:, user_id:, keys:, error:, **) {
  #   Sentry.capture_message("permission cache: #{operation} failed for user #{user_id}")
  # }

  # Whether a database transaction reads from a snapshot (REPEATABLE READ or
  # stronger). Inside such a transaction a permission hash is built for the
  # request and not cached, and regenerate_permissions / invalidate_permissions
  # take effect in the cache once the transaction has committed.
  #   :auto  — yes on MySQL and SQLite; on PostgreSQL only inside a transaction
  #            opened with isolation: :repeatable_read or :serializable
  #   true   — always (PostgreSQL with a raised default_transaction_isolation)
  #   false  — never (MySQL run at READ COMMITTED): a transaction changes nothing
  config.snapshot_transactions = :auto

  # Table name prefix ('' for no prefix)
  config.table_name_prefix = 'permission_forge_'

  # UUID generation
  config.uuid_generator = -> { SecureRandom.uuid }

  # created_by_id / updated_by_id on the live row (a convenience, not the audit log)
  config.audit_trail_enabled = true
  config.audit_user_class = 'User'

  # ---------------------------------------------------------------------------
  # Audit event log (docs/audit-log.md)
  # ---------------------------------------------------------------------------

  # Record events in the audit_events table:
  #   :auto  (default) when the table exists; a missing table logs a boot warning
  #          and changes still work, unrecorded
  #   true   always (under the default :raise strategy a missing table then fails every change)
  #   false  never (events are still published as notifications)
  config.audit_events = :auto

  # Who acts in an admin UI or API request: lambda(controller) returning a user,
  # a PermissionForge::Audit::Actor or { type:, id:, label: }. nil falls back to
  # current_user_resolver, then (admin UI under HTTP Basic) the checked username.
  config.audit_actor_resolver = nil
  # Under HTTP Basic auth with Rails 8's authentication generator (its sign-in does not run in the admin):
  # config.audit_actor_resolver = ->(controller) { Session.find_by(id: controller.request.cookie_jar.signed[:session_id])&.user }

  # Request id and IP stored with each event: lambda(controller) returning
  # { request_id:, ip: }. nil stores request.request_id and request.remote_ip.
  config.audit_request_context = nil

  # When a change's event cannot be written (every Audit.record: changes, views,
  # exports, refusals, housekeeping summaries):
  #   :raise (default) the change rolls back (changes made through the models); :report goes through and is
  #   reported to Rails.error; :log goes through and is only logged
  #   (a refusal written after an open transaction and rake report events are reported, never raised;
  #   the purge always fails closed)
  config.audit_change_failure_strategy = :raise

  # When a subscriber, legacy hook, runtime-event store or resolver fails:
  # :report (default), :log or :raise (the error replaces the decision's outcome)
  config.audit_hook_failure_strategy = :report

  # Runtime (access) events that are STORED; all are published. Any of
  # :denied :bypass :field_read :params_filtered :cache. Assign a new array
  # (the stored one is frozen: `<<` raises).
  config.audit_runtime_events = %i[denied]

  # Also write every audit event (with its data, without name labels) to Rails.logger
  config.audit_log_subscriber = false

  # How long events are kept: a Duration, seconds, or nil (forever). Only the
  # purge (`AuditEventPurger` or `rake permission_forge:audit_events:purge`) deletes,
  # only events older than the period, never `audit.purged`.
  config.audit_retention_period = nil

  # Who may read the audit log pages, exports and API endpoint:
  # lambda(controller), allowed only when it returns exactly true. nil: anyone
  # who can reach the admin.
  config.audit_log_authorization = nil
  # config.audit_log_authorization = ->(_controller) { PermissionForge.current_user&.auditor? == true }

  # Who may change who holds a Permission Set or belongs to a group, in the admin
  # UI and the API (asked after api_assignment_authorization). 4 arguments:
  #   controller, target (PermissionSet or PermissionSetGroup),
  #   user_ids (Array in the user key type), action
  # action is one of :grant :revoke :change_expiry :review :add_member :remove_member.
  # A truthy answer allows; a refusal changes nothing and is an event
  # (admin.auth_failed / api.auth_failed). Consent withdrawal and erasure are
  # data-subject duties and are not gated by it. nil: no extra check.
  config.admin_assignment_authorization = nil
  # config.admin_assignment_authorization = lambda { |controller, _target, user_ids, _action|
  #   !user_ids.include?(PermissionForge.current_user&.id) # nobody assigns themselves
  # }

  # Fields to skip when auto-generating resource fields
  config.ignored_fields = %w[id uuid password encrypted_password ...]  # add created_at updated_at to give them no row

  # Field name variants (auto-creates permission entries for derived names)
  config.field_variant_mappings = {
    /_id\z/    => ->(name) { "#{name.sub(/_id\z/, '')}_uuid" },
    /_cents\z/ => ->(name) { name.sub(/_cents\z/, '') }
  }

  # Method name for models to declare extra virtual permission fields
  config.extra_fields_method = :extra_fields_for_permissions

  # What a declared virtual field gets when no admin has configured it:
  #   :grant        — readable and editable (default, backward-compatible)
  #   :unconfigured — no implicit access; follows unconfigured_field_strategy
  config.extra_fields_default_access = :grant

  # Also list store accessors and attribute-API attributes as virtual fields
  # in the admin. They never get implicit access.
  config.virtual_field_discovery = false

  # Mask virtual readers on the model itself (see docs/masked-attributes.md):
  #   false / nil — off (default); :auto — every model with MaskedAttributes;
  #   ['Customer'] — only these models
  config.mask_virtual_attributes = false

  # ---------------------------------------------------------------------------
  # Controller actions (see docs/controller-actions.md)
  # ---------------------------------------------------------------------------

  # List the app's controller actions on a Resource's Actions tab.
  config.controller_action_discovery = false

  # Map a controller action to a Resource and an action key. Return
  # [resource, key], false (never managed) or nil (use the convention).
  #   config.controller_action_resolver = ->(controller_path, action_name) {
  #     ['Customer', 'merge'] if controller_path == 'customers/merges' && action_name == 'create'
  #   }
  config.controller_action_resolver = nil

  # Controllers never listed or guarded: Regexps, or Strings naming a
  # controller or a namespace. Default: Rails' own controllers. Add to it:
  #   config.controller_discovery_exclude += ['webhooks/']
  config.controller_discovery_exclude = [
    %r{\A(rails|active_storage|action_mailbox|action_cable|action_text|turbo)(/|\z)}
  ]

  # What the guard does with an action no Permission Set manages:
  #   :allow — let it through (default); :block — deny until a set permits it
  # Unknown values behave as :block (fail closed).
  config.unconfigured_action_strategy = :allow

  # People the guard never checks.
  #   config.action_guard_bypass = ->(user, _controller) { user.admin? }
  config.action_guard_bypass = nil

  # What the guard does with a mapped action when nobody is signed in:
  #   nil (or blank) — follow nil_user_strategy (default)
  #   :bypass        — let it through
  #   :deny          — refuse it (ActionNotAuthorizedError); :raise and
  #                    unknown values refuse too
  # The generated initializer sets :deny for new installs.
  config.action_guard_nil_user_strategy = nil

  # Profile data cached alongside permissions
  config.profile_builder = ->(user) {
    { id: user.id, uuid: user.try(:uuid), name: user.try(:name), email: user.try(:email).presence || user.try(:email_address) }
  }

  # ---------------------------------------------------------------------------
  # Activation Conditions
  # ---------------------------------------------------------------------------

  # Request context used to evaluate permission-set activation conditions
  # (session flag, allowed IPs, login hours). Returns a hash with optional
  # keys: :ip, :session_flags, :time. Without this, conditional sets have
  # nothing to check against — a boot warning fires if conditional sets exist
  # while the resolver returns {}. It runs on every permission read of a user
  # who holds a conditional set: keep it cheap, return {} (or anything with
  # #to_h) where there is no request, and never read permissions inside it
  # (that raises ConfigurationError).
  #   config.request_context_resolver = -> {
  #     { ip: Current.ip, session_flags: Current.session_flags, time: Time.current }
  #   }
  config.request_context_resolver = -> { {} }

  # How conditional sets are treated without a request context:
  #   false — a blank context lets every conditional set count (fail-open,
  #           backward-compatible default; boot warning); any other context
  #           is evaluated set by set
  #   true  — with no request context (nothing, or neither an IP nor session
  #           flags: a job, the console) conditional granting sets are
  #           dropped and conditional muting sets still apply (recommended)
  config.conditional_sets_strict_mode = false

  # ---------------------------------------------------------------------------
  # Multi-Tenancy (optional, requires the acts_as_tenant gem)
  # ---------------------------------------------------------------------------

  # Tenant model class name (e.g., 'Account' or 'Billing::Account'). nil = disabled.
  # Requires the tenant column on all PermissionForge tables; boot fails when
  # set while the acts_as_tenant gem is not loaded.
  config.tenant_model = nil

  # Foreign key column for the tenant association, passed to acts_as_tenant.
  # Default: inferred from tenant_model (e.g., 'Account' -> :account_id)
  config.tenant_column = nil

  # Admin UI and admin API requests that have no current tenant while
  # tenant_model is set:
  #   :deny  — refused with a 403 (admin.auth_failed / api.auth_failed,
  #            reason tenant_missing) (default; unknown values behave as :deny)
  #   :allow — served: they read, edit and delete existing records of every
  #            tenant; creating a record still needs a tenant (422)
  config.admin_tenantless_access = :deny

  # ---------------------------------------------------------------------------
  # Security Defaults
  # ---------------------------------------------------------------------------

  # Strategy for fields not mapped in the permission hash:
  #   :block        — exclude unmapped fields (secure default, recommended)
  #   :mask_all     — apply full masking to unconfigured fields
  #   :warn         — pass through but log a warning
  #   :pass_through — pass through unmasked (NOT recommended for production)
  # Unknown values fall back to :block (fail closed).
  config.unconfigured_field_strategy = :block

  # Behavior of FiltersResponseAttributes when there is no current user
  # (system/console/background context):
  #   :bypass — return attributes unfiltered (backward-compatible default)
  #   :block  — return {} (strict fail-closed)
  # When a user IS present but has no configured access to the resource, every
  # field is routed through unconfigured_field_strategy regardless of this setting.
  config.response_filter_nil_user_strategy = :bypass

  # Behavior of MaskedAttributes (model masking) when there is no current user:
  #   :bypass           — getters, attributes and as_json return the stored
  #                       values (default). Inside a web request each guarded
  #                       attribute so returned is logged (once per model and
  #                       process) and published as field.unmasked_without_user.
  #   :hide_in_requests — hidden inside a web request (a public page, a
  #                       webhook, a controller that forgot authentication, a
  #                       before_action or middleware before sign-in); jobs,
  #                       rake, the runner and the console keep the stored
  #                       values. The generated initializer and :strict set it.
  #   :hide             — every guarded attribute reads as hidden_attribute_value
  #                       everywhere. Jobs and mailers that read masked models
  #                       with no user then see hidden values: set the current
  #                       user there.
  #   Where it hides, the primary key and the raw paths (read_attribute_before_type_cast,
  #   pluck) are untouched, the user model (user_class and its subclasses) is
  #   exempt (sign-in reads it before anyone is signed in), and validations
  #   read the stored values.
  config.masked_attributes_nil_user_strategy = :bypass

  # What row-level rules do when current_user is nil: find_by / find_by! /
  # permission_scoped, auto-scoping, the generated RLS policies, and the
  # controller action guard while action_guard_nil_user_strategy is nil.
  # (Model masking does not follow it: see masked_attributes_nil_user_strategy.)
  #   :bypass — skip the rules (backward-compatible default)
  #   :raise  — find_by / find_by! / permission_scoped raise NotAuthorizedError;
  #             auto-scoping and RLS return no rows (recommended for production)
  #   :deny   — find_by returns nil; permission_scoped, auto-scoping and RLS
  #             return no rows
  # The guard lets the request through only for :bypass.
  # A String is taken as its Symbol; any other value raises ConfigurationError.
  # Inside PermissionForge.without_permission_scope { }, with nobody signed in,
  # find_by / find_by! / permission_scoped apply no rules whatever this says.
  config.nil_user_strategy = :bypass

  # What the same reads do for a SIGNED-IN user whose Permission Sets do not
  # grant read_access on the model's Resource (no entry at all included):
  #   :rules_only — apply the rules of the user's entries; no rules there,
  #                 every row (default; check can_read? in the controller)
  #   :deny       — no rows: permission_scoped and auto-scoping return none,
  #                 find_by / find_by! raise NotAuthorizedError for an
  #                 existing record (the strict preset's value)
  config.no_read_access_strategy = :rules_only

  # A `<assoc>_attributes` payload (PermitsAttributes) for a child model the
  # user has no Resource entry for:
  #   false — dropped (default, fail closed)
  #   true  — filtered against the parent resource's fields, as before 0.14
  #           (not recommended; `rake permission_forge:audit` reports it)
  config.nested_attributes_parent_fallback = false

  # ---------------------------------------------------------------------------
  # Query scoping (see docs/query-scoping.md)
  # ---------------------------------------------------------------------------

  # Level 1: apply filter-type rules to every relation on a protected model.
  #   :off (default) | :filter_only. Other values raise ConfigurationError.
  config.auto_query_scoping = :off

  # Level 2: report queries on protected tables that skipped the rules.
  #   :off (default) | :log | :raise. Other values raise ConfigurationError.
  config.unscoped_query_detection = :off
  config.unscoped_query_detection_environments = %w[development test]

  # Level 3 (PostgreSQL): set the session variable the generated RLS
  # policies read (policies come from `rails generate permission_forge:rls`).
  config.database_row_level_security = false
  config.rls_session_variable = 'permission_forge.user_id'

  # Callback when view_all/modify_all bypasses row-level rules.
  # Kept for compatibility: it is a subscriber of the rule.bypassed audit event
  # (see docs/audit-log.md). Errors follow audit_hook_failure_strategy.
  config.on_rule_bypass = nil
  # config.on_rule_bypass = ->(user:, resource:, reason:) {
  #   Rails.logger.info("[PF Audit] #{user.id} bypassed rules on #{resource} via #{reason}")
  # }

  # Optional callback for field-level audit logging. A subscriber of the
  # field.access audit event (errors follow audit_hook_failure_strategy); called
  # once per field decision, as it is made when it is the only listener and
  # field_read is not stored, otherwise when the read returns.
  # Called for each field processed by FiltersResponseAttributes.
  # Receives: lambda(resource_name:, field_name:, action:, user:)
  # action is one of: :hidden, :masked, :passed
  config.on_field_filtered = nil

  # ---------------------------------------------------------------------------
  # Masking & MaskedAttributes
  # ---------------------------------------------------------------------------

  # Custom mask strategies: hash of strategy_name => callable(value).
  # Merged with the built-ins (full, email, last4, first1_last4) in
  # MaskValue.strategies.
  config.custom_mask_strategies = {}

  # Auto-apply the MaskedAttributes concern to host models:
  #   :auto / true          — every model that has a Resource record (default)
  #   ['Customer', 'Order'] — only these named models
  #   false / nil           — no auto-apply; include the concern manually
  # :auto costs one cache-store read per request and job; a list, or false with
  # `include PermissionForge::Concerns::MaskedAttributes` in each model
  # (recommended in production), reads nothing per request.
  config.auto_apply_masked_attributes = :auto

  # Value returned by MaskedAttributes when read_access is denied.
  config.hidden_attribute_value = nil

  # When true (default), MaskedAttributes omits hidden keys from `attributes` /
  # `as_json` / `serializable_hash`. When false, keys are present with
  # hidden_attribute_value.
  config.omit_hidden_in_attributes_hash = true

  # Guard against persisting a masked/hidden sentinel back to the database
  # (e.g., a before_save callback reading a masked getter and writing it back):
  #   :skip  — silently keep the original stored value (default, safe)
  #   :raise — raise MaskedAttributes::MaskedWriteError (surfaces the bug)
  #   :off   — disable the guard (legacy behavior; risks silent corruption)
  config.masked_write_protection = :skip

  # ---------------------------------------------------------------------------
  # GDPR / Data Protection
  # ---------------------------------------------------------------------------

  # When true, ResourceFieldGenerator auto-masks PII fields (email, phone, name, etc.),
  # except when full access is asked for (grant_all: true, grant_full_access!)
  config.gdpr_defaults = true

  # When true, raises ConfigurationError at boot if gdpr_defaults was never explicitly set.
  config.gdpr_require_explicit_choice = false

  # Override or extend sensitive field patterns
  config.gdpr_field_patterns = PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS

  # Automatically append GDPR field patterns to Rails log filtering.
  # Default: true (sensitive fields are redacted in logs, error reporters, etc.)
  # The patterns also reach ActiveRecord::Base.filter_attributes, so a matching
  # attribute prints as [FILTERED] in #inspect and pretty_print.
  config.filter_parameters_integration = true

  # ---------------------------------------------------------------------------
  # Admin UI (HTML)
  # ---------------------------------------------------------------------------

  # HTTP Basic Auth for the mounted admin UI (enabled by default).
  # When enabled but credentials are not set, every request returns 401.
  # Do NOT disable without replacing it with your own auth (see base_controller_class).
  config.http_basic_auth_enabled = true
  config.http_basic_auth_user = nil       # e.g., ENV['PF_ADMIN_USER']
  config.http_basic_auth_password = nil   # e.g., ENV['PF_ADMIN_PASSWORD']

  # Base controller class for the admin UI. Override to inherit your own
  # authenticated controller (Devise, Warden, etc.):
  #   config.base_controller_class = '::Admin::BaseController'
  config.base_controller_class = '::ActionController::Base'

  # Locales available in the admin UI. nil (default) falls back to
  # PermissionForge::BUNDLED_LOCALES ([:en, :sq, :mk]) so the UI never renders
  # host-app locales the gem can't translate.
  config.available_locales = nil

  # Admin screens only (never affect permission checks):
  config.admin_model_resolver = nil          # models offered in "Add a resource" (nil = all app models)
  config.admin_session_flags = {}            # { 'mfa_verified' => 'Signed in with two-factor' }
  config.admin_stale_assignment_days = 90    # "Stale assignments" threshold on Home
  config.admin_app_name = nil                # name in "← Back to <app>" (nil = Rails app name)
  config.admin_back_url = nil                # target of that link (String or ->(view) { ... }; nil = host root)
  config.admin_docs_url = 'https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md'

  # ---------------------------------------------------------------------------
  # Admin JSON API
  # ---------------------------------------------------------------------------

  # When true, the JSON endpoints under /api/ answer. The routes are always
  # drawn; while this is false every API request gets a 404 with no body.
  config.api_enabled = false

  # Authentication lambda — nil = 401 all requests (safe default)
  config.api_auth = nil

  # Base controller class — defaults to ActionController::Base.
  # IMPORTANT: Override to inherit your app's auth chain (Devise, Warden, etc.)
  config.api_base_controller_class = '::ActionController::Base'

  # Action-level authorization for every create, update, destroy, clone and
  # generate_fields. Receives (controller, action, record), action a Symbol
  # (:create, :update, :destroy, :clone, :generate_fields); a truthy answer allows.
  config.api_action_authorization = nil

  # Assignment authorization — prevents privilege escalation.
  # Receives (controller, target, user_ids): target is the PermissionSet, or
  # the PermissionSetGroup on group-member endpoints; user_ids is an Array in
  # the user key type (Integers for integer keys) on every endpoint.
  config.api_assignment_authorization = nil

  # true (default): until api_action_authorization and
  # api_assignment_authorization are both set, API changes and assignments are
  # refused (403, api.auth_failed). false lets every caller api_auth admits
  # change permissions (boot warning; `rake permission_forge:audit` finding
  # api_mutations_unguarded).
  config.api_require_authorization = true

  # Pagination — hard cap prevents DoS via large result sets
  config.api_max_per_page = 100
  config.api_default_per_page = 15
  config.api_pagination_handler = nil  # nil = built-in LIMIT/OFFSET paginator

  # Stats endpoint closed until api_stats_authorization says who may read it
  config.api_stats_require_admin = true
  config.api_stats_authorization = nil  # ->(controller) { PermissionForge.current_user&.admin? }

  # Record identifier for URL lookups
  config.api_record_identifier = :uuid

  # Serializer overrides
  config.api_serializer_overrides = {}

  # When true, PermissionSetRuleSerializer replaces field_value with "[REDACTED]"
  # in API responses. Rule field_values can contain sensitive data (user IDs,
  # account numbers). Enable for GDPR/HIPAA environments.
  config.api_redact_rule_field_values = false
end
```

## Cache Consistency

Permission caching is read-through: a cache miss (first access, TTL expiry, eviction, store flush) transparently rebuilds the hash in the current request, so `permissions_hash` never silently returns an empty hash. Permission changes (`after_commit` on permission records and assignments) invalidate the affected users' cache entries; each user's hash is rebuilt lazily on their next permission check, in their own request context. There is a brief race condition window between a permission change and the cache invalidation where concurrent requests may read stale permissions. This window is typically milliseconds.

**Transactions.** On a database whose transactions read committed rows — PostgreSQL at its default — a transaction changes nothing: permissions are cached and invalidated inside it as outside it. On a database whose transactions read from a snapshot (MySQL at its default, SQLite; PostgreSQL inside `transaction(isolation: :repeatable_read)` or `:serializable`) a hash built inside a transaction is used by the request and not cached, because it may be older than a change that has already been invalidated; `user.regenerate_permissions` and `user.invalidate_permissions` called there take effect in the cache once the transaction has committed. `config.snapshot_transactions` (`:auto` by default) decides which applies; set it to `true` for a PostgreSQL whose default isolation level was raised for the database or the role, and to `false` for a MySQL that runs at READ COMMITTED.

On a snapshot database, read the permissions once (`current_user.permissions_hash`, or any authorisation check) before a loop of saves or before a long transaction opens: permissions first read inside a transaction are built once per transaction and not cached — 50 saves on a cold entry build the hash 50 times (350 queries) instead of once (7). The log says so once per process when it keeps happening. Details and the known limits: [architecture.md](architecture.md#inside-a-transaction).

**In development, share the cache between processes.** An invalidation reaches the cache of the process that makes it. Rails 8.0+ generates `config.cache_store = :memory_store` in `config/environments/development.rb` (Rails 7.1 and 7.2: `:memory_store` after `bin/rails dev:cache`, `:null_store` otherwise), and the generated initializer caches through `Rails.cache` — so each process (the server, a console, `bin/rails runner`, a rake task) has a cache of its own. A permission change made from a console, a runner or a rake task (seeds, `permission_forge:cleanup_expired_assignments`, an erasure) invalidates only that process's copy, and the running server keeps serving the permissions it had cached until `cache_ttl` (an hour by default) or a restart; a change made in the server's own admin UI applies at once. The boot logs a warning in development when the permission cache is per process (`cache_backend = :memory`, or a `:memory_store`). Either share the store:

```ruby fragment
# config/environments/development.rb
config.cache_store = :file_store, "tmp/cache/store"
```

or switch caching off in development (`config.cache_backend = :null if Rails.env.development?` in the initializer). A `:null_store` caches nothing, so it has no stale copy either. In production the same applies across Puma workers, which is why `:memory` there gets a boot warning of its own.

**The same store carries auto-applied masking.** While `auto_apply_masked_attributes` (or `mask_virtual_attributes`) is `:auto`, a process that commits the first `Resource` row for a model tells the others through a token in the cache store ([Masked attributes](masked-attributes.md#how-other-processes-learn-about-a-new-model-maskingsync)). A per-process store (`:memory`, a `:memory_store`) or one that keeps nothing (`:null`, a `:null_store`) carries it to no other process: a `Customer` row created from `bin/rails runner` left the server's `Customer` unmasked — emails in clear while `masked_field?` said `true` — until a restart. In development the server therefore re-reads the `Resource` names from the database instead, one query at most every 2 seconds, so such a model is masked at its next request; no other environment runs that query. The development boot says so when the store is one of these, and production warns that a model first named in another process stays unmasked there until a restart. The remedies: a store every process shares (as above), or `include PermissionForge::Concerns::MaskedAttributes` in each model that holds personal data with `auto_apply_masked_attributes = false` (the recommended production setup, [below](masked-attributes.md#recommended-in-production-include-the-concern-explicitly)), or a list of models in `auto_apply_masked_attributes`.

### What reports the cache scope

Every operation that clears cached permissions reports one outcome — whether the store confirmed the removal
(`confirmed`), whether the store lives in each process (`process_local`: `cache_backend = :memory`, or `Rails.cache`
a `:memory_store`), where it ran (`in_request`: in a web server process — a request the admin or the API served, or any
code of a server process such as a host controller) and how many users the
store did not confirm (`unconfirmed`) — the same way everywhere:

| Operation | Terminal | Admin flash | API | Audit event |
|---|---|---|---|---|
| `rake permission_forge:cache:clear` / `PermissionCacheClearer` | "Cached permissions removed", "Cache scope", "Ran in" lines | — | — | `cache.cleared` |
| `rake permission_forge:erasure` / Erase / `DataSubjectErasure` | same | Erased… (+ scope) | — | `erasure.performed`, then `cache.settled` |
| `rake permission_forge:cleanup_expired_assignments` / Home Clean-up / `ExpiredAssignmentCleaner` | same | Removed N expired assignments (+ scope) | — | `cleanup.expired_assignments` |
| Withdraw consent / `ConsentWithdrawalHandler` | — | Removed N Permission Sets… (+ scope) | — | `consent.withdrawn`, then `cache.settled` |
| Bulk assign / revoke (admin, API) / `BulkPermissionSetAssignment` | — | Assigned/Revoked… (+ scope) | `cache: { confirmed, process_local, in_request, unconfirmed }` | the per-row `assignment.*` events |
| One assignment (assign, change the end, keep, remove, restore, undo), a batch of edits (Review and save) | — | the usual notice, an alert when not confirmed (+ scope) | `POST …/users`, `DELETE …/users/:uuid`: `meta.cache` | the per-row events |
| Refresh cached permissions, Remove all access | — | (+ scope) | — | — |

In Ruby the services answer the outcome under `cache:` (a Hash with the four keys); `confirmed` is `nil` inside a
transaction of yours (the invalidation follows its commit) — every service the same way (`Cache::Report#deferred?`).
`erasure.performed` and `consent.withdrawn` are written before the cache work; `cache.settled`, on the same
correlation id, records what the store answered (after your transaction's commit when there is one). On a per-process store a run from a rake task, a runner,
a console or a job clears nothing in the web and job processes; a run from an admin or API request clears the serving
process's store only — the other workers and the job processes keep theirs until they restart or the entries expire
(`cache_ttl`). A host controller that calls a service directly counts as the serving process too (its process is a
web server).

### Where warnings appear

Every boot and configuration warning of the gem — the per-process cache above, conditional sets with an empty request
context, the API enabled without authorization lambdas, unmasked GDPR fields, join rules under auto-scoping, missing or
stale RLS policies, a model a `Resource` row names that cannot be masked, `audit_events = false`, a shared Basic-auth
login without `audit_actor_resolver`, a model class that loaded with another setting — is written by one emitter with
one policy:

- **The log, always** (`Rails.logger.warn`, prefixed `[PermissionForge]`; a fail-open condition is prefixed
  `[PermissionForge] SECURITY warning:`).
- **Standard error as well, where the log is not read:** in development (`bin/rails server` boots before it attaches
  its console logger; a console, `bin/rails runner`, a rake task and `db:seed` never attach one), and in every other
  environment but test in any process that is not a web server — a console, a runner, a rake task, a seed, a job worker.
  A server in production or staging gets the log only. Each warning is written there once per process.
- **A warning about the admin screens or the JSON API is the server's:** HTTP Basic auth without credentials, a shared
  Basic-auth login without `audit_actor_resolver`, an API-only host missing the admin's middlewares, tenantless admin
  access and the API enabled without its authorization lambdas (a SECURITY warning under
  `api_require_authorization = false`; otherwise a note naming what the API refuses) describe what a web server
  process serves. Every other
  process (a console, `bin/rails runner`, a rake task, `db:seed`, a job worker) writes them to the log only, never to
  standard error: it serves no admin, and credentials set for the server alone (`PF_ADMIN_USER` / `PF_ADMIN_PASSWORD`)
  would read as missing there. Every other warning (the cache, masking, rules, the audit table, RLS) is about data
  every process uses and keeps the policy above.
- **What counts as a web server process:** one started by `bin/rails server` (`Rails::Server`), `puma`
  (`Puma::CLI`), `unicorn` or `unicorn_rails` (`Unicorn::Launcher`), Passenger (`PhusionPassenger::App`, its Rack
  loader), `falcon serve` or `falcon host` (`Falcon::Command`), or `pitchfork` and `rackup` (by program name: their
  commands define no constant of their own) — `PermissionForge::Warnings::SERVER_COMMANDS` and `SERVER_PROGRAMS`.
  Each constant is one the server's command loads before it boots the app, never one `Bundler.require` loads in a
  runner. A program name is the name the process was started with (`Process.argv0`, which pitchfork's process titles
  do not change) or `$0` (which `bundle exec rackup` sets to the binstub it loads). These are the limits: a server
  started some other way (thin, your own Rack launcher script, a renamed binstub) is not recognised
  and counts as a process whose log is not read — its standard error gets the warnings, and the admin and API warnings
  go to its log only.
- **Not twice:** when the logger already writes to standard output or error (a container, `RAILS_LOG_TO_STDOUT`, the
  Rails 7.1+ production default), nothing is written to standard error.
- **Nothing while `bin/rails generate` or `destroy` runs:** the install generator boots the app before it writes the
  initializer, so its warnings would describe the defaults the app is about to stop having. The next server, console or
  task boot checks the configuration the app has.

There is no switch for the standard-error copy: each warning names the setting that removes its condition (a shared
cache store, the authorization lambdas, `conditional_sets_strict_mode`, masking the field, ...), and the warning goes
with it.

**When the cache store is unreachable** nothing is raised and access never widens: requests work with the hash they build. An invalidation that could not be made is reported (`config.on_cache_failure`), and the process that failed makes it when the store answers again — see [architecture.md](architecture.md#when-the-cache-store-fails) for what that does and does not cover.

**Clearing everything.** Use `bin/rails permission_forge:cache:clear` (or `PermissionForge::Services::PermissionCacheClearer.call(actor:, reason:)`). It removes every user's cached permissions in every tenant, by key pattern where the store can (Redis, memory and file stores, checked with canary keys — an in-memory store, `cache_backend = :memory` or `:memory_store`, lives in each process, so the task clears only its own, and says so) and otherwise by invalidating every user, retires the memos of the process that runs it, and is recorded as `cache.cleared`. The cache is cold afterwards: each user rebuilds once on their next request. On Redis the pattern is a glob (`<cache_key_prefix>:user_*`, `<cache_key_prefix>:tenant_*_user_*` and the same under `v2:`), which also removes the invalidation stamps and any key of your own that matches it: keep `cache_key_prefix` to PermissionForge's keys.

`PermissionForge.cache.clear` is the low-level call: it removes every key under `cache_key_prefix` (the invalidation stamps and the managed-actions index too) on Redis (a `<prefix>:*` glob) and on the memory and file stores (an anchored `/^<prefix>:/`; a store's own `namespace` is respected). It writes no audit event and does not retire memos already held by user instances. Solid Cache and Memcached stores cannot match keys: there it removes nothing, answers `false` and logs a warning. Under `cache_backend = :memory` (PermissionForge's own per-process hash) it empties that process's hash only.

For high-security or high-concurrency deployments:
- Use `:null` cache for maximum security (permissions recomputed every request)
- Lower `cache_ttl` (default: 3600 seconds) for a tighter staleness backstop
- The effective TTL is automatically clamped to `conditional_set_cache_ttl` (default: 300 seconds) when activation-condition sets are involved, and to the soonest assignment `expires_at`
- Invalidate a specific user manually with `user.invalidate_permissions` (accepts `tenant_id:` in multi-tenant setups)

## Breaking Changes in Security Defaults

The following defaults changed for security hardening:

| Config | Old Default | New Default | Migration |
|--------|-------------|-------------|-----------|
| `unconfigured_field_strategy` | `:warn` | `:block` | Set `:warn` explicitly if you rely on pass-through |
| `cache_ttl` | `nil` (never expire) | `3600` | Set `nil` explicitly to restore never-expire (not recommended) |
| `api_stats_require_admin` | `false` | `true` | Set `false` explicitly if non-admin access needed |
| `filter_parameters_integration` | `false` | `true` | Set `false` explicitly to opt out |
| `api_require_authorization` (0.14) | `false` | `true` | Set `api_action_authorization` and `api_assignment_authorization`, or `false` explicitly (not recommended) |
| `nested_attributes_parent_fallback` (0.14, new) | parent fallback | `false` | Set `true` explicitly (not recommended) |
| `admin_tenantless_access` (0.14, new) | tenant-less admin requests served | `:deny` | Set the tenant in the base controllers, or `:allow` |

Users who relied on old defaults can restore them in their initializer.

## Deploying

- **The app boots without a reachable or configured database** (a deploy during a failover, a production runner before the deploy sets `DATABASE_URL`, the commented-out production paths of a `rails new --skip-kamal` database.yml). The boot checks ping the database once; when it cannot be used — refused, not created, or not configured (the sqlite3 adapter's `No database file specified`) — the checks that read it (the security warnings) are skipped with one line that names the cause, `The database could not be reached at boot, or the gem's models could not be loaded (<error>: <message>)`, and auto-applied masking is applied at the first request or job that reaches the database; until the `Resource` table can be read, a request or job does not read the masking token from the cache store either (a Solid Cache store whose database is not configured stays quiet). A database host that drops packets costs the adapter's connect timeout once at boot; a refused connection is immediate.
- **An asset build never touches the database.** A process that runs nothing but `assets:precompile`, `assets:clean` or `assets:clobber` (the Dockerfile's `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile`) runs the configuration warnings only: no ping, no database check, no masking sync. A task that reads data inside such a build (one hung onto `assets:precompile` with `enhance`) therefore does not get the auto-applied concern: include `MaskedAttributes` in the model for that. A command that also names another task (`bin/rails assets:precompile db:seed`), or a task that depends on `assets:precompile`, is not an asset build and runs every check.
- **Use a shared cache store in production** (`:rails_cache` over Redis, Memcached or Solid Cache, or a store instance). Invalidations reach every process through it, and so does masking that is auto-applied when a `Resource` row names a new model: every process checks one token in the store at the start of each request or job. Under `:memory` or `:null` (or a `:memory_store` / `:null_store`), other processes pick a newly named model up only at their next boot (in development: within 2 seconds, from the database — see [Cache Consistency](#cache-consistency)).
- **Names must not be blank.** A Permission Set, Permission Set Group, field or action whose name is blank is refused when it is created or renamed (422 in the API). Rows whose name is already blank stay editable in their other attributes.

## Presets

`config.preset` sets the options that decide whether something fails open, all at once. It is a layer of defaults: a setting you make yourself wins, before or after `config.preset =`, in whichever `configure` block.

- `:compat` (the default): the library defaults, as every version had them.
- `:strict`: every fail-open default of the [Production hardening checklist](https://github.com/fetijashari/permission_forge#production-hardening-checklist) that a setting can close, and the defaults that are already closed kept so. The install generator writes it as a comment.

| Option | `:compat` | `:strict` |
|---|---|---|
| `nil_user_strategy` | `:bypass` | `:deny` |
| `response_filter_nil_user_strategy` | `:bypass` | `:block` |
| `auto_query_scoping` | `:off` | `:filter_only` |
| `no_read_access_strategy` | `:rules_only` | `:deny` |
| `unconfigured_action_strategy` | `:allow` | `:block` |
| `action_guard_nil_user_strategy` | `nil` | `:deny` |
| `conditional_sets_strict_mode` | `false` | `true` |
| `mask_virtual_attributes` | `false` | `:auto` |
| `extra_fields_default_access` | `:grant` | `:unconfigured` |
| `cache_backend` | `:memory` | `:rails_cache` |
| `masked_attributes_nil_user_strategy` | `:bypass` | `:hide_in_requests` |
| `api_require_authorization`, `admin_tenantless_access`, `nested_attributes_parent_fallback`, `unconfigured_field_strategy` | `true`, `:deny`, `false`, `:block` | the same |

What `:strict` leaves open:

- Masking with nobody signed in outside web requests: `:strict` sets `masked_attributes_nil_user_strategy = :hide_in_requests`, so jobs, rake, the runner and the console keep reading stored values (`bin/rails permission_forge:audit` notes it as `masked_nil_user_outside_requests`, info). `:hide` closes that too, at the cost of hidden values in jobs and mailers that read masked models with no user; it counts as closed, not as a looser override.
- The rows of the hardening checklist that need your code: an authenticated `base_controller_class` (and `api_base_controller_class`), `admin_assignment_authorization`, `audit_log_authorization`, a `request_context_resolver` for conditional Permission Sets, and `user_active_check`.

So `:strict` is not "every finding closed": run the audit after setting it.

What `:strict` costs: with `nil_user_strategy :deny` and `auto_query_scoping :filter_only`, code that runs with no current user (jobs, mailers, seeds, webhooks, the console, sign-in lookups on a user model that includes `PermissionScopedFindable`) sees no protected rows, and a `belongs_to` presence check on a protected parent fails ("must exist"). An idempotent seed is the easy one to miss: `Customer.find_or_create_by!(name: ...)` run with nobody signed in finds no row and creates a duplicate on every run. Run such code with a user, or inside `PermissionForge.without_permission_scope { }`: there `where`, `find`, `find_by` and `permission_scoped` apply no rules when nobody is signed in (a signed-in user's `find_by` and `permission_scoped` still apply theirs), so never put it around code an anonymous request reaches. Do not include `PermissionScopedFindable` in the user model. With `no_read_access_strategy :deny`, a signed-in user whose sets do not grant Read on a protected model finds none of its records either (auto-scoping included, so also through an association or a `belongs_to` presence check): give each role Read on the models its pages and validations load. A conditional Permission Set needs a `request_context_resolver` that returns the request's IP and session flags, or its grant never applies.

```ruby fragment
PermissionForge.configure do |config|
  config.preset = :strict
  config.nil_user_strategy = :bypass # wins over the preset
end
```

The preset takes `:strict`, `:compat` or their String; anything else raises `PermissionForge::ConfigurationError`. `bin/rails permission_forge:audit` prints the preset, and under `:strict` reports `strict_overrides` (low) naming each option set looser than the preset (`:raise` for a nil-user strategy, `:null` or your own store for `cache_backend` are not looser).

## Option values and hooks

**Strategy options are checked when they are set.** `nil_user_strategy`, `no_read_access_strategy`, `response_filter_nil_user_strategy`, `masked_attributes_nil_user_strategy`, `masked_write_protection`, `action_guard_nil_user_strategy`, `admin_tenantless_access`, `unconfigured_action_strategy`, `extra_fields_default_access`, `auto_query_scoping`, `unscoped_query_detection` and the audit options take a Symbol from their list; a String is taken as its Symbol, and any other value raises `PermissionForge::ConfigurationError` in the initializer. (`action_guard_nil_user_strategy` also takes `nil` or blank.)

**What counts as "yes" in a hook.** Most hooks allow on any truthy answer, so a lambda that returns a relation, a String or `1` allows. Two require exactly `true`:

| Hook | Allows on |
|---|---|
| `api_auth`, `api_action_authorization`, `api_assignment_authorization`, `admin_assignment_authorization` | any truthy value |
| `audit_log_authorization`, `action_guard_bypass` | exactly `true` (anything else does not allow: the audit log is refused, the action guard is not bypassed and the Permission Sets decide) |

Return a real boolean from every hook (`current_user&.admin? == true`, `.exists?`), never a relation.

## How people are labelled and searched

**Labels** (`Admin::PersonLabel`). With `user_label_formatter` set, a person's name is what it returns (blank falls through to the next step). Otherwise the first non-blank of `name`, `full_name`, `display_name`, then `first_name` + `last_name` (or `firstname` + `lastname`) joined with a space, then the email (`email`, else `email_address`, the column Rails 8's `bin/rails generate authentication` creates), then `User #<id>`. Each can be a column or a method: a column is read as stored (`read_attribute_before_type_cast`, so masking on your User model never garbles the admin), and the public reader is used for a method or a blank column. A column your User model encrypts (`encrypts :email`) is read decrypted, through the attribute's type (never its ciphertext). The email, when the user has one, is shown under the name.

**Search** depends on what `user_list_resolver` returns:

- **A relation** (the default `user_model.order(:id)`, or any `ActiveRecord::Relation`): search runs in SQL. It looks at whichever of the columns in `Admin::PeopleCandidates::Relation::SEARCH_COLUMNS` your user table has (`name`, `email`, `email_address`, `full_name`, `display_name`, `first_name`, `last_name`, `firstname`, `lastname`, `username`, `login`), case-insensitive and anywhere in the value. Every word of the query must match one of those columns, so "ana kras" finds Ana Krasniqi whether the name is one column or two. A query of digits also matches the id. A name that exists only as a method is not searched (search the columns it is built from), and `user_label_formatter` does not change what is searched. A column your User model encrypts holds ciphertext, so it is not searched for words: one encrypted with `deterministic: true` matches the whole query exactly (as typed, or lower-cased: `where(email: query)`), any other is not searched at all — and bulk assignment matches a pasted email or name the same way.
- **An Array** (e.g. `-> { User.active.sort_by(&:name) }`): search runs in Ruby over each person's label and email (the label from `user_label_formatter` when set), as one case-insensitive substring of the whole query. The resolver runs each time the admin screens or the API list, search or look up people by id, so **every user it returns is loaded into memory** each time; `user_list_limit` caps only what a picker shows. Prefer a relation for large user tables: order and scope it in SQL (`-> { User.active.order(:last_name, :first_name) }`).

## Option reference

One entry per option, in the order the admin **Settings** page shows them (its "Configuration docs" links point here), then the options that page does not show. The **Default** line of each entry is generated from the code (`bundle exec rake docs:configuration`), so it is the default of `PermissionForge::Configuration.new` in this version; a strategy option also lists the values it takes. Set these in `config/initializers`. `user_class`, `audit_user_class` and `tenant_model` are read by the models as they load; a change made later does not reach a loaded class (PermissionForge logs a warning).

<!-- option-reference:start -->
<!-- Generated by `bundle exec rake docs:configuration` from SettingsCatalog and Configuration.new.
     Edit the text under a heading here (or settings.items.<option> in the en locale for a new option):
     the headings, their order and the **Default:** lines are regenerated. -->

### Preset

#### preset

**Default:** `:compat`

**Preset.** `:strict` closes the settings that fail open by default; `:compat` (the default) keeps the library defaults. A setting made in the initializer always wins. See [Presets](#presets).

### Admin access

#### http_basic_auth_enabled

**Default:** `true`

**Password-protect this admin.** Asks for a shared username and password before anyone can open these screens.

#### http_basic_auth_user

**Default:** `nil`

**Admin username.** Username for the password prompt above.

#### http_basic_auth_password

**Default:** `nil`

**Admin password.** Password for the password prompt above. Never shown here.

#### base_controller_class

**Default:** `'::ActionController::Base'`

**Admin controller.** The app controller these screens inherit from. This is where your own sign-in check runs.

#### admin_assignment_authorization

**Default:** `nil`

**Who may change assignments.** Code that decides whether a request may change who holds a Permission Set or belongs to a Permission Set Group, in these screens and in the API. It is called with `(controller, target, user_ids, action)`: `target` is the `PermissionSet` or `PermissionSetGroup`, `user_ids` the people concerned, `action` one of `:grant`, `:revoke`, `:change_expiry`, `:review`, `:add_member`, `:remove_member`. A truthy answer allows, a falsy one refuses (the request changes nothing, the screens show a message, the API answers 403, and the refusal is recorded as `admin.auth_failed` / `api.auth_failed`); an exception fails the request. Multi-set actions ask once per set and refuse everything if any set is refused. In the API it runs after `api_assignment_authorization`. It is asked by the admin screens and the API before a grant, expiry change, review, revocation or membership change; consent withdrawal, erasure, the expired-assignment clean-up, assignments removed with a deleted Permission Set or group, and Ruby/console calls are not gated by it. Not set means no extra check.

### People

#### user_class

**Default:** `'User'`

**People model.** The model that represents a person who can receive Permission Sets.

#### current_user_resolver

**Default:** the gem's own lambda

**How the current user is found.** Tells PermissionForge who is signed in on each request. The generated initializer sets `-> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }`, which works with or without a `Current` class (Rails 8's authentication generator creates one). Until it returns your signed-in user, nobody is signed in and `nil_user_strategy` decides — with the default `:bypass`, nothing is restricted.

#### user_active_check

**Default:** the gem's own lambda

**Active-person check.** Tells PermissionForge whether an assigned person's account is still active. It does not remove access: only `rake permission_forge:audit` (its assignment check) reads it, to report assignments still held by people it calls inactive. Revoke those assignments, or remove them when you deactivate the account.

#### user_list_resolver

**Default:** `nil` (the built-in behaviour)

**People list source.** Which people appear in pickers on these screens (a relation is searched in SQL, an Array in Ruby: see [How people are labelled and searched](#how-people-are-labelled-and-searched)), **and which people these screens and the API can reach by id**: a person the resolver leaves out is not found (404) on the person page, erasure, assignment, restore, group membership, bulk assignment and the API's assignment endpoints. Lists of a set's holders still show every holder of the set. With tenancy on and a users table that is not tenant-scoped, scope the resolver to the current tenant's users.

#### user_list_limit

**Default:** `500`

**People list limit.** Maximum people loaded into a list before asking you to search.

#### user_label_formatter

**Default:** `nil` (the built-in behaviour)

**Person label.** How a person is shown in lists, for example name and email. See [How people are labelled and searched](#how-people-are-labelled-and-searched).

#### profile_builder

**Default:** the gem's own lambda

**Profile details.** The profile details cached with each person's permissions (`permissions_hash[:profile]`). The default builds `{ id:, uuid: user.try(:uuid), name: user.try(:name), email: user.try(:email).presence || user.try(:email_address) }` (`email_address` is the column Rails 8's authentication generator creates; the key stays `email`).

The profile lives in the cache store with the permission hash (Redis, Solid Cache, ...). The default leaves out an attribute your User model encrypts (`encrypts :email`): its value is `nil` there — neither the ciphertext nor the plaintext is cached (before 0.15 the ciphertext was), and an encrypted `email` gives way to a plain `email_address`. A name or email your model composes in a reader (`def name = "#{first_name} #{last_name}"`) is left out too while the model encrypts any attribute a name or email is read from (`name`, `full_name`, `display_name`, `first_name`/`last_name`, `firstname`/`lastname`, `email`, `email_address`); an encrypted attribute none of those is, read by your own reader, is not detected — set a `profile_builder` of your own then. The admin's own labels still read them decrypted; they are never cached. The generated initializer leaves `profile_builder` to this default (its line is a commented example). An initializer generated before 0.15 sets its own lambda, which calls the public readers — they decrypt, so it caches the plaintext: remove the line to get the default, or change it.

Your User model needs no `uuid` column: `uuid` is then `nil`, and `permission_set_granted_by` / `permission_set_granted_updated_by` in `source_permission_sets` hold the granting user's uuid when the user model has one, else its id.

### Field protection

#### unconfigured_field_strategy

**Default:** `:block`

**Fields without a setting.** What happens to a column that no Permission Set mentions.

#### response_filter_nil_user_strategy

**Default:** `:bypass` Takes `:bypass` or `:block` (or its String).

**Responses with nobody signed in.** Whether field filtering is skipped or everything is blocked when there is no current user.

#### custom_mask_strategies

**Default:** `{}`

**Custom mask styles.** Extra masking styles defined in code, offered next to the built-in ones. Removing a strategy that field rows still name does not break reads: those fields are masked fully until you pick another strategy in the admin (the rows stay editable), and `rake permission_forge:audit` lists them under `unknown_mask_strategies`.

#### ignored_fields

**Default:** `%w[id token_digest token_last_digits created_by updated_by token password encrypted_password deleted_at uuid deactivated]`

**Ignored columns.** Columns PermissionForge never manages. They don't appear in field lists and get no generated row (under `unconfigured_field_strategy = :block` a column without a row reads as hidden). The list is frozen: extend it with `config.ignored_fields += %w[internal_flag]`, not `<<`. Since 0.15 the default no longer lists `created_at` / `updated_at`: generating fields gives Rails' timestamps a row instead, at most read-only on a granting set (see [Rails timestamps](masked-attributes.md#rails-timestamps)); `config.ignored_fields += %w[created_at updated_at]` restores the old behaviour. On an existing install the admin lists the two columns as not configured on every resource until you sync its fields or add them to `ignored_fields`.

#### field_variant_mappings

**Default:** `/_id\z/` (owner_id → owner_uuid), `/_cents\z/` (amount_cents → amount)

**Linked field variants.** A field's setting also applies to these related names, where the model has them (a column or attribute, an alias, a public reader or writer, or a declared virtual field). See [Field Variant Mappings](field-filtering.md#field-variant-mappings).

#### extra_fields_method

**Default:** `:extra_fields_for_permissions`

**Virtual fields method.** Model method that lists extra, non-database fields to protect.

#### extra_fields_default_access

**Default:** `:grant` Takes `:grant` or `:unconfigured` (or its String).

**Virtual fields without a setting.** Whether a virtual field nobody configured is editable by default (`:grant`) or follows “Fields without a setting” (`:unconfigured`).

#### virtual_field_discovery

**Default:** `false`

**Discover virtual fields.** Also lists store accessors and attribute-API attributes as virtual fields. Discovered names never get access until an admin sets a level.

#### on_field_filtered

**Default:** `nil`

**When a field is hidden or masked.** Code that runs each time a field is filtered, for example to log it.

### Masked attributes on models

#### auto_apply_masked_attributes

**Default:** `:auto`

**Mask model attributes automatically.** Applies masking when the app reads attributes directly, not only in responses. `:auto` (default) masks every model a Resource row names, in every process, for one cache-store read per request and job — through a cache store every process shares ([Cache Consistency](#cache-consistency)). A list of model names, or `false` with `include PermissionForge::Concerns::MaskedAttributes` in each model (recommended in production), reads nothing per request. See [Masked attributes](masked-attributes.md).

#### masked_write_protection

**Default:** `:skip` Takes `:skip`, `:raise` or `:off` (or its String).

**Saving masked values.** Stops a masked value like “•••• 4821” from being saved back over the real one.

#### masked_attributes_nil_user_strategy

**Default:** `:bypass` Takes `:bypass`, `:hide_in_requests` or `:hide` (or its String).

**Masked attributes with nobody signed in.** Whether a masked model's getters, `attributes` and `as_json` return the stored values (`:bypass`, the default), hide every guarded attribute inside a web request only (`:hide_in_requests`), or hide every guarded attribute everywhere (`:hide`) when there is no current user. The primary key and the raw paths stay as they are. Takes a Symbol or its String; anything else raises `ConfigurationError`.

*A web request* is any request the application serves, from the top of its middleware stack (the engine puts `PermissionForge::WebRequest::Middleware` first) until the response is finished: your controllers, the mounted engine, the middlewares and `before_action`s that run before sign-in (a tenant or subdomain lookup), and a job run with `perform_now` or a mail sent with `deliver_now` during the request. Outside one: jobs run by a worker (also `perform_later` on the `:async` adapter), Action Cable channel actions, rake tasks, `bin/rails runner`, the console, and `ActionController::TestCase` tests (they call the controller without the middleware stack; integration and system tests go through it). With Falcon or another fiber-based server, set `config.active_support.isolation_level = :fiber`, as Rails requires.

Under `:bypass`, each guarded attribute returned as stored inside a web request with nobody signed in — exactly what `:hide_in_requests` would hide — is published as the runtime audit event `field.unmasked_without_user` (group `:bypass`, stored when `audit_runtime_events` includes it; once per request per model and attribute: the model, the attribute, the request's method, path and endpoint) and written to the log as one SECURITY warning per model and process. `rake permission_forge:audit` reports `:bypass` as `masked_nil_user_bypass` (medium) and `:hide_in_requests` as `masked_nil_user_outside_requests` (info). The generated initializer and `config.preset = :strict` set `:hide_in_requests`; the library default stays `:bypass`, because hiding before sign-in changes what an existing app's public pages and pre-authentication lookups read. Under `:hide` and `:hide_in_requests` the user model (`user_class` and its subclasses) is exempt: authentication reads it before anyone is signed in (Devise's `encrypted_password`, `confirmation_token`, lockable counters), so with nobody signed in its columns, password digests included, read as stored: do not render it with no current user (`permission_forge:audit` reports `user_model_unmasked_without_user`). Another authenticatable model (a second Devise scope) is not exempt. Validations always read stored values.

#### hidden_attribute_value

**Default:** `nil`

**Value for hidden attributes.** What a hidden attribute returns when code reads it.

#### omit_hidden_in_attributes_hash

**Default:** `true`

**Leave hidden fields out of attribute lists.** Hidden fields are removed from attribute hashes instead of being set to empty.

#### mask_virtual_attributes

**Default:** `false`

**Mask virtual fields on models.** Also hides or masks computed, non-database fields when your code reads them from the model. Off by default; `:auto` for every model with masked attributes, or a list of model names.

### Record rules & query scoping

#### nil_user_strategy

**Default:** `:bypass` Takes `:bypass`, `:raise` or `:deny` (or its String).

**Record rules with nobody signed in.** Whether rules are skipped, deny everything, or raise an error when there's no current user. It governs:

- `find_by` / `find_by!` / `permission_scoped`: `:bypass` skips the rules, `:deny` finds nothing (`nil`, `RecordNotFound`, `none`), `:raise` raises `NotAuthorizedError`;
- auto-scoping (`auto_query_scoping`): `:bypass` adds nothing, `:deny` and `:raise` return no rows (it never raises from inside a scope);
- the generated RLS policies: `:bypass` lets a session without the session variable see every row, anything else hides every row (re-sync after changing it);
- the controller action guard, while `action_guard_nil_user_strategy` is nil or blank: only `:bypass` lets the request through.

Inside `PermissionForge.without_permission_scope { }`, with nobody signed in, `find_by`, `find_by!` and `permission_scoped` apply no rules whatever this says (reported as `rule.bypassed`, `scope_suspended`).

It does not govern model masking (`masked_attributes_nil_user_strategy`) or response filtering (`response_filter_nil_user_strategy`). A String is taken as its Symbol (`'deny'` is `:deny`); any other value raises `ConfigurationError` when it is set.

#### no_read_access_strategy

**Default:** `:rules_only` Takes `:rules_only` or `:deny` (or its String).

**Records without read access.** What record lookups and queries return for a signed-in user whose Permission Sets do not grant Read on the resource: the rows the record rules allow (with no rule, every row), or none. It governs `find_by` / `find_by!` / `permission_scoped` and the default scope of `auto_query_scoping`, for a user who has no entry for the model's Resource (or for an entry of its single-table-inheritance chain: a subclass with no Resource of its own reads as its base), or one of whose entries does not grant `read_access`:

- `:rules_only` (the default, as every version had it): the reads apply the rules of the user's entries; a user with no entry, or an entry without read, has no rules there and gets every row. `can_read?` is the check — ask it in the controller, or let [`ControllerActionGuard`](controller-actions.md) ask it.
- `:deny` (the strict preset's value): no rows. `permission_scoped` and the default scope return `none`; `find_by` and `find_by!` raise `NotAuthorizedError` for a record that exists, with one `failure_messages` entry from the locale (`permission_forge.denials.no_read_access`: "You do not have permission to read Customer records."), and return `nil` / raise `RecordNotFound` for one that does not. Each denial is an `access.denied` event with reason `no_read_access`. Whatever took read away counts: no Permission Set grants it, a Muting Permission Set takes it, a Resource row renamed off its model, a granting set whose activation conditions do not pass or cannot be judged. View All and Modify All skip the rules of an entry that grants read; they never stand in for it.

With nobody signed in, `nil_user_strategy` decides. Where the rules are lifted, this is lifted with them: `PermissionForge.without_permission_scope { }` lifts the default scope (and, with nobody signed in, `find_by` / `permission_scoped`); a signed-in user's `find_by` and `permission_scoped` keep applying both inside it. The generated RLS policies follow it as well (part of the policy digest: re-sync after switching it; see [Read access in a policy](query-scoping.md#read-access-in-a-policy)). A String is taken as its Symbol; any other value raises `ConfigurationError` when it is set.

#### on_rule_bypass

**Default:** `nil`

**When rules are skipped.** Code that runs when View All or Modify All skips the record rules.

#### auto_query_scoping

**Default:** `:off`

**Apply rules to all queries.** Filter rules are added to every query automatically. Rules that follow a relationship only apply to scoped lookups.

#### unscoped_query_detection

**Default:** `:off`

**Detect unprotected queries.** Notices queries that skip record rules.

#### unscoped_query_detection_environments

**Default:** `%w[development test]`

**Detection runs in.** Environments where unprotected-query detection is on.

#### database_row_level_security

**Default:** `false`

**Database row-level security.** Lets the database itself enforce record rules as a last line of defence.

#### rls_session_variable

**Default:** `'permission_forge.user_id'`

**Database session variable.** Name of the variable that tells the database who the current user is.

#### rule_secret_column_patterns

**Default:** `[/\Apassword_digest\z/, /_digest\z/, /token/, /\Aencrypted_/, /_secret/, /passw/, /\Asecret(?:_|\z)/, /(?:\A|_)(?:api|private|secret|access)_key\z/, /(?:\A|_)crypted(?:_|\z)/, /(?:\A|_)salt\z/, /(?:\A|_)otp(?:_|\z)/]`

**Secret column patterns.** The column names a record rule may not compare (`PermissionForge::SecretColumns`, matched against the column name — after the rule's association path, qualified or not — in lower case). The defaults also name passwords and their salts (`*passw*`, `*_salt`), `secret*`, API / private / secret / access keys (`*_key` after one of those words only: `sort_key` stays allowed) and OTP seeds (`otp_*`), each tied to a name segment. A new rule on such a column, or a change of a rule's column, path, join type or model to one, is refused (`names a column that holds a secret`), and the admin's rule builder does not offer these columns. A rule stored before keeps evaluating as it did and stays editable in its other attributes, except its value and operator (a new value would be another guess at the secret); `rake permission_forge:audit` (`secret_rule_columns`) and the admin's Home list it. `[]` opts out; a narrower list (`[/\Apassword_digest\z/]`) keeps only those.

### Controller actions

See [controller-actions.md](controller-actions.md).

#### controller_action_discovery

**Default:** `false`

**List controller actions.** Shows your app's controller actions on a resource's Actions tab so they can be permitted or blocked.

#### controller_action_resolver

**Default:** `nil` (the built-in behaviour)

**Controller action mapping.** Decides which resource and action a controller action belongs to. Returns `[resource, key]`, `false` (never managed) or `nil` (use the convention); anything else, or a name that is not valid, raises `PermissionForge::ConfigurationError`.

#### controller_discovery_exclude

**Default:** `[/\A(rails|active_storage|action_mailbox|action_cable|action_text|turbo)(\/|\z)/]`

**Controllers left out.** Controllers that are never listed or checked: Regexps, or Strings naming a controller or a namespace (`'webhooks'` covers `webhooks` and `webhooks/*`). Blank entries are ignored. PermissionForge's own controllers are always left out.

#### unconfigured_action_strategy

**Default:** `:allow` Takes `:allow` or `:block` (or its String).

**Actions without a setting.** What happens to a controller action that no Permission Set mentions: `:allow` (default) or `:block`.

#### action_guard_bypass

**Default:** `nil`

**Who skips the action check.** People for whom controller actions are never checked, for example administrators.

#### action_guard_nil_user_strategy

**Default:** `nil` (the built-in behaviour) Takes `:bypass`, `:deny` or `:raise` (or its String), or nil.

**Action check with nobody signed in.** What the guard does with a mapped action when there is no current user. `nil` or blank (the default) follows `nil_user_strategy`; `:bypass` lets the request through; `:deny` refuses it (`ActionNotAuthorizedError`), and so do `:raise` and unknown values. The generated initializer sets `:deny` for new installs; existing installs keep following `nil_user_strategy` until they set it.

### Activation conditions

#### request_context_resolver

**Default:** the gem's own lambda

**Request details source.** Where IP address, time and session flags come from. Called on every permission read of a user who holds a conditional set (never for other users): keep it cheap, return `{}` (or anything with `#to_h`) outside a request, and never read permissions inside it, which raises `PermissionForge::ConfigurationError`.

#### conditional_sets_strict_mode

**Default:** `false`

**Strict activation conditions.** With no request context (the resolver returns nothing, or neither an IP nor session flags), strict mode drops conditional granting sets and keeps conditional muting sets. Without it, a blank context lets every conditional set count. See [Activation Conditions](activation-conditions.md#strict-mode).

### Privacy (GDPR)

#### gdpr_defaults

**Default:** `true`

**Privacy defaults.** When true, a column that looks like personal data (`gdpr_field_patterns`, plus the columns `filter_parameters` name while `filter_parameters_integration` is on) is created **Masked** by every path that generates rows at Read-only; Hidden stays Hidden, full access masks nothing. The recommended strategy is recorded on every generated row.

#### gdpr_require_explicit_choice

**Default:** `false`

**Require a privacy-defaults choice.** The app refuses to boot until privacy defaults are switched on or off explicitly.

#### gdpr_field_patterns

**Default:** `PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS`

**Sensitive name patterns.** Column names matching a pattern are flagged sensitive and get this mask style.

#### filter_parameters_integration

**Default:** `true`

**Filter sensitive values from logs.** Adds the privacy patterns to Rails' filter_parameters so logs don't show them. The patterns also reach `ActiveRecord::Base.filter_attributes` (Rails copies `config.filter_parameters` there), so a matching attribute of your models (`name` and `email` included) prints as `[FILTERED]` in `#inspect`, `pretty_print` and error reports. The gem's own configuration models keep the other filters but show their `name`, `label` and `field_name` (a Permission Set's name is not personal data); `AuditEvent#actor_label` and `#record_label`, which hold people's names, are filtered whenever your filters hide a `name`. While on, the columns your `filter_parameters` name (`api_token`, `license_key`, …) also count as personal data for the admin's presets and Sync (Masked on Read-only under `gdpr_defaults`), `rake permission_forge:audit_masks`, the `personal_data` audit check and the boot warning (recommended strategy `full`). A String or Symbol entry names a column when one of the column name's `_`-separated segments starts with it (`:otp` names `otp_secret`, not `footprint`); a leading or trailing underscore ties it to a segment boundary (`:_key` names `api_key`, and also `sort_key`); a Regexp entry matches as written; a Proc entry names no column.

**The patterns apply to the whole app, by parameter name.** Rails matches them against every parameter key, at any depth, whatever the form: a bare `name` key is filtered everywhere — a product's, a team's, and the admin's own forms (a Permission Set, a Resource, a field) — so request logs show `"name" => "[FILTERED]"` for values that are not personal data. To narrow it, add the patterns yourself without the one that matches a bare `name`, and filter `name` only under the forms that carry a person's name. Below the `configure` block of `config/initializers/permission_forge.rb`:

```ruby fragment
# in the configure block: config.filter_parameters_integration = false

patterns = PermissionForge.gdpr_filter_parameters
bare_name = patterns.select { |pattern| pattern.match?('name') } # the one that also covers first_name, ...
Rails.application.config.filter_parameters +=
  (patterns - bare_name) + [/first_name|last_name|full_name|contact_name/, 'user.name', 'customer.name']
```

A String with a dot (`'customer.name'`) matches the nested key `customer[name]` only. `PermissionForge.gdpr_filter_parameters` reads `gdpr_field_patterns`, so set those in the `configure` block above it. Masking detection keeps using every GDPR pattern (`gdpr_field_patterns`); with the integration off it no longer also reads your own `filter_parameters` (a column only your filters name is not flagged as sensitive in the admin). `rake permission_forge:audit` keeps reporting `log_filtering_off` (low) because the setting is false — it cannot tell your own filtering apart from none, so read that finding as done once the lines above are in place.

### Caching

#### cache_backend

**Default:** `:memory`

**Cache store.** Where computed permissions are cached.

Under `:rails_cache` the store is `Rails.cache`: in development that is a per-process `:memory_store` unless you change it, and a change made from a console or rake task does not reach the server — see [Cache Consistency](#cache-consistency).

On Rails 7.1 and 7.2 with connection_pool 3.x, `ActiveSupport::Cache::RedisCacheStore.new(url: …)` raises `ArgumentError` when it builds its connection pool (a Rails/connection_pool incompatibility, not PermissionForge's). Pin `connection_pool` below 3, or pass `pool: false`, until you upgrade Rails.

#### cache_key_prefix

**Default:** `'pf'`

**Cache key prefix.** Prefix for every cache entry.

#### cache_ttl

**Default:** `3600`

**Cache lifetime.** How long computed permissions are kept. A new value applies to entries cached after the change; entries already in the store keep the TTL they were written with.

#### conditional_set_cache_ttl

**Default:** `300`

**Conditional set cache lifetime.** How long permissions are kept for people with conditional sets: the base entry and its per-context variants. Selection happens on every read; this is a backstop. It is also how long the variants an invalidation leaves stay in the store (unreachable); with this and `cache_ttl` both `nil` they stay until written over, an erasure or `cache:clear`.

#### snapshot_transactions

**Default:** `:auto`

**Transactions read from a snapshot.** Whether a database transaction keeps seeing the data as it was when it began. Permissions computed inside such a transaction are not cached. Auto decides from the database: MySQL and SQLite do, PostgreSQL only at repeatable read or stronger.

#### on_cache_failure

**Default:** `nil`

**When the cache store fails.** Code that runs when cached permissions could not be cleared, for example to alert you. Until the cache lifetime ends, that person may keep their old permissions.

### Audit log

The audit event log is described in [audit-log.md](audit-log.md); these are its options.

A value the log cannot work with is refused with `PermissionForge::ConfigurationError` when it is set (at configure time): `audit_events` other than `:auto`, `true` or `false` (a string from `ENV` is refused, not read as `:auto`), a failure strategy that is not one of its values, an `audit_runtime_events` group that is not one of `denied bypass field_read params_filtered cache`, and an `audit_retention_period` that is not a positive Duration, a positive number of seconds or `nil`.

#### audit_trail_enabled

**Default:** `true`

**Record who created and last edited.** Stamps them on the 8 permission models when the acting person is a record of `audit_user_class`; API clients, HTTP Basic logins, system and Hash actors stamp nothing and leave the previous editor. A convenience on the live row, not the audit log.

#### audit_user_class

**Default:** `'User'`

**Audit people model.** The model used for “created by” and “edited by”.

#### audit_events

**Default:** `:auto`

**Audit log.** Records each change made through the permission models — the actor as resolved (possibly `unknown`), when, and the previous values — in the `audit_events` table. `:auto` (default): on when the table exists. `true`: always (under the default `:raise` strategy a missing table then fails every change). `false`: never (events are still published).

#### audit_actor_resolver

**Default:** `nil` (the built-in behaviour)

**Who is recorded as the actor.** Code that names who acts in a request to these screens or the API. Not set means the signed-in person; under HTTP Basic, the username.

#### audit_request_context

**Default:** `nil` (the built-in behaviour)

**Request details on events.** Code that gives the request id and IP address stored with each event. Not set means `request.request_id` and `request.remote_ip`.

#### audit_change_failure_strategy

**Default:** `:raise`

**When a change cannot be recorded.** `:raise` (default) rolls the change back; `:report` lets it through and reports it; `:log` lets it through and only logs it. This covers every event written with `Audit.record`; a refusal written after an open transaction and the events of a rake report are reported, never raised, and the purge always fails closed.

#### audit_hook_failure_strategy

**Default:** `:report`

**When a subscriber fails.** What happens when a subscriber, legacy hook, runtime-event store or resolver fails: `:report` (default), `:log` or `:raise`.

#### audit_runtime_events

**Default:** `%i[denied]`

**Stored runtime events.** Which runtime decisions are stored, not only published: `denied` (default), `bypass`, `field_read`, `params_filtered`, `cache`.

#### audit_log_subscriber

**Default:** `false`

**Copy events to the log.** Also writes every audit event, with its data but without name labels, to the application log.

#### audit_retention_period

**Default:** `nil`

**Keep audit events for.** How long audit events are kept before the purge task may delete them. Not set means forever.

#### audit_log_authorization

**Default:** `nil` (the built-in behaviour)

**Who may read the audit log.** Code that decides who may read the audit log, its exports and the API endpoint; allowed only when it returns exactly `true`. Not set means anyone with access to these screens.

### Multi-tenancy

#### tenant_model

**Default:** `nil` (off)

**Tenant model.** Model that separates customers of a multi-tenant app.

#### tenant_column

**Default:** `nil` (off)

**Tenant column.** Column that holds the tenant on each record.

#### admin_tenantless_access

**Default:** `:deny` Takes `:deny` or `:allow` (or its String).

**Admin requests with no tenant.** What the admin screens and the admin API do with a request that has no current tenant while `tenant_model` is set. `:deny` (default) refuses it with a 403, recorded as `admin.auth_failed` / `api.auth_failed` with reason `tenant_missing`. `:allow` serves it: it reads, edits and deletes existing records of **every** tenant, but creating a record still needs a tenant (refused as invalid, 422 in the API). Only the exact `:allow` (or `'allow'`) allows; anything else denies. Set the tenant in `base_controller_class` / `api_base_controller_class` (or middleware) instead — see [multi-tenancy.md](multi-tenancy.md).

### Admin JSON API

#### api_enabled

**Default:** `false`

**JSON API.** Lets other systems manage Permission Sets over HTTP.

#### api_auth

**Default:** `nil`

**API sign-in.** How API callers prove who they are. Called with the controller; a falsy answer is a 401 (`api.auth_failed`, reason `api_auth_denied`). Not set: every request is a 401. What an authenticated caller may change is `api_action_authorization` / `api_assignment_authorization` (403).

#### api_base_controller_class

**Default:** `'::ActionController::Base'`

**API controller.** The controller API endpoints inherit from.

#### api_action_authorization

**Default:** `nil`

**API permission check.** Decides which API calls each caller may make.

#### api_assignment_authorization

**Default:** `nil`

**API assignment check.** Decides who may assign Permission Sets through the API. Called with `(controller, target, user_ids)`: `target` is the `PermissionSet`, or the `PermissionSetGroup` on the group-member endpoints; `user_ids` is an Array cast to the user model's key type (Integers for integer keys) on every endpoint. A truthy answer allows.

#### api_require_authorization

**Default:** `true`

**Require API permission checks.** Default `true`: until `api_action_authorization` and `api_assignment_authorization` are both set, API changes and assignments are refused (403, `api.auth_failed`). `false` lets every caller `api_auth` admits change permissions and assign anyone (boot warning; `rake permission_forge:audit` finding `api_mutations_unguarded`).

#### api_stats_require_admin

**Default:** `true`

**Stats only for admins.** Only admins can read usage statistics through the API. Default `true`: `GET /api/stats` answers only callers `api_stats_authorization` allows (403 otherwise, also while it is unset). `false`: every caller `api_auth` admits.

#### api_stats_authorization

**Default:** `nil`

**API stats check.** Decides who may read usage statistics through the API while `api_stats_require_admin` is on. Called with the controller; a truthy answer allows, anything else is a 403 recorded as `api.auth_failed` (reason `stats_not_authorized`). Not set: the stats are refused. Replaces an `api_auth` that sets `@admin = true` on the controller, which still allows while this is unset (deprecated, removed in 0.16).

#### api_record_identifier

**Default:** `:uuid`

**API record identifier.** Which identifier the API uses in URLs.

#### api_default_per_page

**Default:** `15`

**Default page size.** Records per API page when the caller doesn't say.

#### api_max_per_page

**Default:** `100`

**Maximum page size.** Upper limit on records per API page.

#### api_pagination_handler

**Default:** `nil` (the built-in behaviour)

**Pagination.** How API results are split into pages.

#### api_serializer_overrides

**Default:** `{}`

**Custom serializers.** Overrides for how records are written in API responses.

#### api_redact_rule_field_values

**Default:** `false`

**Hide rule values in the API.** Rule values are redacted in API responses.

### Admin screens

#### admin_model_resolver

**Default:** `nil` (the built-in behaviour)

**Models offered in the admin.** Which models are offered when you add a resource.

#### admin_session_flags

**Default:** `{}`

**Session flag names.** Friendly names for session flags offered on the Conditions tab.

#### admin_stale_assignment_days

**Default:** `90`

**Review assignments after.** Permanent assignments not reviewed for this long appear under Stale assignments. Also the default threshold of `rake permission_forge:stale_assignments` and `StaleAssignmentAuditor`.

#### admin_app_name

**Default:** `nil` (the built-in behaviour)

**App name.** The app name shown under the logo in these screens.

#### admin_back_url

**Default:** `nil` (the built-in behaviour)

**"Back to app" link.** Where the link under the logo leads (default: your app's home page). A String, or a lambda receiving the view context, e.g. `->(view) { view.main_app.dashboard_path }`.

#### admin_docs_url

**Default:** `'https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md'`

**Configuration docs link.** Where the “Configuration docs” links on this page point to.

### Database & system

#### table_name_prefix

**Default:** `'permission_forge_'`

**Table prefix.** Prefix for PermissionForge's own database tables.

#### uuid_generator

**Default:** the gem's own lambda

**UUID generator.** How record UUIDs are created.

#### available_locales

**Default:** `nil` (the built-in behaviour)

**Languages.** Languages these screens are available in.

### Other options

#### api_only_admin_warning

**Default:** `true`

**API-only boot warning.** In an application with `config.api_only = true` that mounts the engine, the log says which middlewares the admin screens need (cookies, session, flash; see [Admin UI](admin-ui.md#api-only-applications)) once the routes are drawn: at boot, or at the first request where Rails 8 draws them lazily (development and test). Set it to `false` in an app that uses only the JSON API and never opens the admin screens.

#### nested_attributes_parent_fallback

**Default:** `false`

**Nested payloads without a child resource.** Not on the Settings page. How `PermitsAttributes` treats a `<assoc>_attributes` payload for a child model the user has no Resource entry for. `false` (default) drops the payload. `true` filters it against the parent resource's fields, as before 0.14 — a key editable on the parent then admits the same key on a child the user was never granted. Keep it `false`; `rake permission_forge:audit` reports `true` as a medium finding (`nested_parent_fallback`).

<!-- option-reference:end -->
