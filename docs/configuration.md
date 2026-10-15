# Configuration

Before production, go through the Production hardening checklist in the README (https://github.com/fetijashari/permission_forge#production-hardening-checklist).

All configuration options with their defaults. These are the defaults of `PermissionForge::Configuration`; the initializer that `rails generate permission_forge:install` writes is short (the integration points, and the safe part of the hardening checklist: `action_guard_nil_user_strategy = :deny`, `conditional_sets_strict_mode = true` and `cache_backend = :rails_cache`) and offers `config.preset = :strict` commented (see [Presets](#presets)). Every option it leaves out keeps the default shown here.

Set these in `config/initializers`. `user_class`, `audit_user_class` and `tenant_model` are read by the models as they load; a change made later does not reach a loaded class (PermissionForge logs a warning).

```ruby
PermissionForge.configure do |config|
  # Sets every option that decides whether something fails open, all at once
  # (see Presets below). A setting made in this block wins over it, in any order.
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
  # first_name/last_name (or firstname/lastname) → email → `User #<id>`.
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
  config.ignored_fields = %w[id created_at updated_at password encrypted_password ...]

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
    { id: user.id, uuid: user.try(:uuid), name: user.try(:name), email: user.try(:email) }
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
  #   :bypass — getters, attributes and as_json return the stored values (default)
  #   :hide   — every guarded attribute reads as hidden_attribute_value; the
  #             primary key and the raw paths (read_attribute_before_type_cast,
  #             pluck) are untouched. Jobs and mailers that read masked models
  #             with no user then see hidden values: set the current user there.
  #             The user model (user_class and its subclasses) is exempt: sign-in
  #             reads it before anyone is signed in. Validations always read the
  #             stored values. Not part of any preset.
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

  # When true, ResourceFieldGenerator auto-masks PII fields (email, phone, name, etc.)
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

  # Stats endpoint requires admin by default
  config.api_stats_require_admin = true

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

- **The app boots without a reachable database** (for example `assets:precompile` in a Docker build, or a deploy during a failover). The boot checks ping the database once; when it cannot be reached, the checks that read it (the security warnings) are skipped with one log line, and auto-applied masking is applied at the first request or job that reaches the database. A database host that drops packets costs the adapter's connect timeout once at boot; a refused connection is immediate.
- **Use a shared cache store in production** (`:rails_cache` over Redis, Memcached or Solid Cache, or a store instance). Invalidations reach every process through it, and so does masking that is auto-applied when a `Resource` row names a new model: every process checks one token in the store at the start of each request or job. Under `:memory` or `:null`, other processes pick a newly named model up only at their next boot.
- **Names must not be blank.** A Permission Set, Permission Set Group, field or action whose name is blank is refused when it is created or renamed (422 in the API). Rows whose name is already blank stay editable in their other attributes.

## Presets

`config.preset` sets the options that decide whether something fails open, all at once. It is a layer of defaults: a setting you make yourself wins, before or after `config.preset =`, in whichever `configure` block.

- `:compat` (the default): the library defaults, as every version had them.
- `:strict`: every fail-open default of the [Production hardening checklist](https://github.com/fetijashari/permission_forge#production-hardening-checklist) that a setting can close, except masking with nobody signed in, and the defaults that are already closed kept so. The install generator writes it as a comment.

| Option | `:compat` | `:strict` |
|---|---|---|
| `nil_user_strategy` | `:bypass` | `:deny` |
| `response_filter_nil_user_strategy` | `:bypass` | `:block` |
| `auto_query_scoping` | `:off` | `:filter_only` |
| `unconfigured_action_strategy` | `:allow` | `:block` |
| `action_guard_nil_user_strategy` | `nil` | `:deny` |
| `conditional_sets_strict_mode` | `false` | `true` |
| `mask_virtual_attributes` | `false` | `:auto` |
| `extra_fields_default_access` | `:grant` | `:unconfigured` |
| `cache_backend` | `:memory` | `:rails_cache` |
| `api_require_authorization`, `admin_tenantless_access`, `nested_attributes_parent_fallback`, `unconfigured_field_strategy` | `true`, `:deny`, `false`, `:block` | the same |

`masked_attributes_nil_user_strategy` is in no preset: `:hide` makes jobs and mailers that read masked models with no user see hidden values, a cost each app chooses for itself.

What `:strict` costs: with `nil_user_strategy :deny` and `auto_query_scoping :filter_only`, code that runs with no current user (jobs, mailers, seeds, webhooks, the console, sign-in lookups on a user model that includes `PermissionScopedFindable`) sees no protected rows, and a `belongs_to` presence check on a protected parent fails ("must exist"). Run such code with a user, or inside `PermissionForge.without_permission_scope { }`: there `where`, `find`, `find_by` and `permission_scoped` apply no rules when nobody is signed in (a signed-in user's `find_by` and `permission_scoped` still apply theirs), so never put it around code an anonymous request reaches. Do not include `PermissionScopedFindable` in the user model. A conditional Permission Set needs a `request_context_resolver` that returns the request's IP and session flags, or its grant never applies.

```ruby
PermissionForge.configure do |config|
  config.preset = :strict
  config.nil_user_strategy = :bypass # wins over the preset
end
```

The preset takes `:strict`, `:compat` or their String; anything else raises `PermissionForge::ConfigurationError`. `bin/rails permission_forge:audit` prints the preset, and under `:strict` reports `strict_overrides` (low) naming each option set looser than the preset (`:raise` for a nil-user strategy, `:null` or your own store for `cache_backend` are not looser).

## Option values and hooks

**Strategy options are checked when they are set.** `nil_user_strategy`, `response_filter_nil_user_strategy`, `masked_attributes_nil_user_strategy`, `masked_write_protection`, `action_guard_nil_user_strategy`, `admin_tenantless_access`, `unconfigured_action_strategy`, `extra_fields_default_access`, `auto_query_scoping`, `unscoped_query_detection` and the audit options take a Symbol from their list; a String is taken as its Symbol, and any other value raises `PermissionForge::ConfigurationError` in the initializer. (`action_guard_nil_user_strategy` also takes `nil` or blank.)

**What counts as "yes" in a hook.** Most hooks allow on any truthy answer, so a lambda that returns a relation, a String or `1` allows. Two require exactly `true`:

| Hook | Allows on |
|---|---|
| `api_auth`, `api_action_authorization`, `api_assignment_authorization`, `admin_assignment_authorization` | any truthy value |
| `audit_log_authorization`, `action_guard_bypass` | exactly `true` (anything else does not allow: the audit log is refused, the action guard is not bypassed and the Permission Sets decide) |

Return a real boolean from every hook (`current_user&.admin? == true`, `.exists?`), never a relation.

## How people are labelled and searched

**Labels** (`Admin::PersonLabel`). With `user_label_formatter` set, a person's name is what it returns (blank falls through to the next step). Otherwise the first non-blank of `name`, `full_name`, `display_name`, then `first_name` + `last_name` (or `firstname` + `lastname`) joined with a space, then `email`, then `User #<id>`. Each can be a column or a method: a column is read as stored (`read_attribute_before_type_cast`, so masking on your User model never garbles the admin), and the public reader is used for a method or a blank column. The email, when the user has one, is shown under the name.

**Search** depends on what `user_list_resolver` returns:

- **A relation** (the default `user_model.order(:id)`, or any `ActiveRecord::Relation`): search runs in SQL. It looks at whichever of the columns in `Admin::PeopleCandidates::Relation::SEARCH_COLUMNS` your user table has (`name`, `email`, `full_name`, `display_name`, `first_name`, `last_name`, `firstname`, `lastname`, `username`, `login`), case-insensitive and anywhere in the value. Every word of the query must match one of those columns, so "ana kras" finds Ana Krasniqi whether the name is one column or two. A query of digits also matches the id. A name that exists only as a method is not searched (search the columns it is built from), and `user_label_formatter` does not change what is searched.
- **An Array** (e.g. `-> { User.active.sort_by(&:name) }`): search runs in Ruby over each person's label and email (the label from `user_label_formatter` when set), as one case-insensitive substring of the whole query. The resolver runs each time the admin screens or the API list, search or look up people by id, so **every user it returns is loaded into memory** each time; `user_list_limit` caps only what a picker shows. Prefer a relation for large user tables: order and scope it in SQL (`-> { User.active.order(:last_name, :first_name) }`).

#### profile_builder

**Profile details.** The profile details cached with each person's permissions (`permissions_hash[:profile]`). The default and the generated initializer build `{ id:, uuid: user.try(:uuid), name: user.try(:name), email: user.try(:email) }`.

Your User model needs no `uuid` column: `uuid` is then `nil`, and `permission_set_granted_by` / `permission_set_granted_updated_by` in `source_permission_sets` hold the granting user's uuid when the user model has one, else its id.

## Option reference

One entry per option, in the order the admin **Settings** page shows them (its "Configuration docs" links point here). Set these in `config/initializers`. `user_class`, `audit_user_class` and `tenant_model` are read by the models as they load; a change made later does not reach a loaded class (PermissionForge logs a warning).

### Preset

#### preset

**Preset.** `:strict` closes the settings that fail open by default, except masking with nobody signed in; `:compat` (the default) keeps the library defaults. A setting made in the initializer always wins. See [Presets](#presets).

### Admin access

#### http_basic_auth_enabled

**Password-protect this admin.** Asks for a shared username and password before anyone can open these screens.

#### http_basic_auth_user

**Admin username.** Username for the password prompt above.

#### http_basic_auth_password

**Admin password.** Password for the password prompt above. Never shown here.

#### base_controller_class

**Admin controller.** The app controller these screens inherit from. This is where your own sign-in check runs.

#### admin_assignment_authorization

**Who may change assignments.** Code that decides whether a request may change who holds a Permission Set or belongs to a Permission Set Group, in these screens and in the API. It is called with `(controller, target, user_ids, action)`: `target` is the `PermissionSet` or `PermissionSetGroup`, `user_ids` the people concerned, `action` one of `:grant`, `:revoke`, `:change_expiry`, `:review`, `:add_member`, `:remove_member`. A truthy answer allows, a falsy one refuses (the request changes nothing, the screens show a message, the API answers 403, and the refusal is recorded as `admin.auth_failed` / `api.auth_failed`); an exception fails the request. Multi-set actions ask once per set and refuse everything if any set is refused. In the API it runs after `api_assignment_authorization`. It is asked by the admin screens and the API before a grant, expiry change, review, revocation or membership change; consent withdrawal, erasure, the expired-assignment clean-up, assignments removed with a deleted Permission Set or group, and Ruby/console calls are not gated by it. Not set means no extra check.

### People

#### user_class

**People model.** The model that represents a person who can receive Permission Sets.

#### current_user_resolver

**How the current user is found.** Tells PermissionForge who is signed in on each request. The generated initializer sets `-> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }`, which works with or without a `Current` class (Rails 8's authentication generator creates one). Until it returns your signed-in user, nobody is signed in and `nil_user_strategy` decides — with the default `:bypass`, nothing is restricted.

#### user_active_check

**Active-person check.** Tells PermissionForge whether an assigned person's account is still active. It does not remove access: only `rake permission_forge:audit` (its assignment check) reads it, to report assignments still held by people it calls inactive. Revoke those assignments, or remove them when you deactivate the account.

#### user_list_resolver

**People list source.** Which people appear in pickers on these screens (a relation is searched in SQL, an Array in Ruby: see [How people are labelled and searched](#how-people-are-labelled-and-searched)), **and which people these screens and the API can reach by id**: a person the resolver leaves out is not found (404) on the person page, erasure, assignment, restore, group membership, bulk assignment and the API's assignment endpoints. Lists of a set's holders still show every holder of the set. With tenancy on and a users table that is not tenant-scoped, scope the resolver to the current tenant's users.

#### user_list_limit

**People list limit.** Maximum people loaded into a list before asking you to search.

#### user_label_formatter

**Person label.** How a person is shown in lists, for example name and email. See [How people are labelled and searched](#how-people-are-labelled-and-searched).

### Field protection

#### unconfigured_field_strategy

**Fields without a setting.** What happens to a column that no Permission Set mentions.

#### response_filter_nil_user_strategy

**Responses with nobody signed in.** Whether field filtering is skipped or everything is blocked when there is no current user.

#### masked_attributes_nil_user_strategy

**Masked attributes with nobody signed in.** Whether a masked model's getters, `attributes` and `as_json` return the stored values (`:bypass`, the default) or hide every guarded attribute (`:hide`) when there is no current user. The primary key and the raw paths stay as they are. Takes a Symbol or its String; anything else raises `ConfigurationError`. `rake permission_forge:audit` reports `:bypass` as `masked_nil_user_bypass` (medium). Not part of any preset. Under `:hide` the user model (`user_class` and its subclasses) is exempt: authentication reads it before anyone is signed in (Devise's `encrypted_password`, `confirmation_token`, lockable counters), so with nobody signed in its columns, password digests included, read as stored: do not render it with no current user (`permission_forge:audit` reports `user_model_unmasked_without_user`). Another authenticatable model (a second Devise scope) is not exempt. Validations always read stored values.

#### custom_mask_strategies

**Custom mask styles.** Extra masking styles defined in code, offered next to the built-in ones.

#### ignored_fields

**Ignored columns.** Columns PermissionForge never manages. They don't appear in field lists. The list is frozen: extend it with `config.ignored_fields += %w[internal_flag]`, not `<<`.

#### field_variant_mappings

**Linked field variants.** A field's setting also applies to these related column names.

#### extra_fields_method

**Virtual fields method.** Model method that lists extra, non-database fields to protect.

#### extra_fields_default_access

**Virtual fields without a setting.** Whether a virtual field nobody configured is editable by default (`:grant`) or follows “Fields without a setting” (`:unconfigured`).

#### virtual_field_discovery

**Discover virtual fields.** Also lists store accessors and attribute-API attributes as virtual fields. Discovered names never get access until an admin sets a level.

#### on_field_filtered

**When a field is hidden or masked.** Code that runs each time a field is filtered, for example to log it.

#### nested_attributes_parent_fallback

**Nested payloads without a child resource.** Not on the Settings page. How `PermitsAttributes` treats a `<assoc>_attributes` payload for a child model the user has no Resource entry for. `false` (default) drops the payload. `true` filters it against the parent resource's fields, as before 0.14 — a key editable on the parent then admits the same key on a child the user was never granted. Keep it `false`; `rake permission_forge:audit` reports `true` as a medium finding (`nested_parent_fallback`).

### Masked attributes on models

#### auto_apply_masked_attributes

**Mask model attributes automatically.** Applies masking when the app reads attributes directly, not only in responses. `:auto` (default) masks every model a Resource row names, in every process, for one cache-store read per request and job. A list of model names, or `false` with `include PermissionForge::Concerns::MaskedAttributes` in each model (recommended in production), reads nothing per request. See [Masked attributes](masked-attributes.md).

#### masked_write_protection

**Saving masked values.** Stops a masked value like “•••• 4821” from being saved back over the real one.

#### hidden_attribute_value

**Value for hidden attributes.** What a hidden attribute returns when code reads it.

#### omit_hidden_in_attributes_hash

**Leave hidden fields out of attribute lists.** Hidden fields are removed from attribute hashes instead of being set to empty.

#### mask_virtual_attributes

**Mask virtual fields on models.** Also hides or masks computed, non-database fields when your code reads them from the model. Off by default; `:auto` for every model with masked attributes, or a list of model names.

### Record rules & query scoping

#### nil_user_strategy

**Record rules with nobody signed in.** Whether rules are skipped, deny everything, or raise an error when there's no current user. It governs:

- `find_by` / `find_by!` / `permission_scoped`: `:bypass` skips the rules, `:deny` finds nothing (`nil`, `RecordNotFound`, `none`), `:raise` raises `NotAuthorizedError`;
- auto-scoping (`auto_query_scoping`): `:bypass` adds nothing, `:deny` and `:raise` return no rows (it never raises from inside a scope);
- the generated RLS policies: `:bypass` lets a session without the session variable see every row, anything else hides every row (re-sync after changing it);
- the controller action guard, while `action_guard_nil_user_strategy` is nil or blank: only `:bypass` lets the request through.

Inside `PermissionForge.without_permission_scope { }`, with nobody signed in, `find_by`, `find_by!` and `permission_scoped` apply no rules whatever this says (reported as `rule.bypassed`, `scope_suspended`).

It does not govern model masking (`masked_attributes_nil_user_strategy`) or response filtering (`response_filter_nil_user_strategy`). A String is taken as its Symbol (`'deny'` is `:deny`); any other value raises `ConfigurationError` when it is set.

#### on_rule_bypass

**When rules are skipped.** Code that runs when View All or Modify All skips the record rules.

#### auto_query_scoping

**Apply rules to all queries.** Filter rules are added to every query automatically. Rules that follow a relationship only apply to scoped lookups.

#### unscoped_query_detection

**Detect unprotected queries.** Notices queries that skip record rules.

#### unscoped_query_detection_environments

**Detection runs in.** Environments where unprotected-query detection is on.

#### database_row_level_security

**Database row-level security.** Lets the database itself enforce record rules as a last line of defence.

#### rls_session_variable

**Database session variable.** Name of the variable that tells the database who the current user is.

### Controller actions

See [controller-actions.md](controller-actions.md).

#### controller_action_discovery

**List controller actions.** Shows your app's controller actions on a resource's Actions tab so they can be permitted or blocked.

#### controller_action_resolver

**Controller action mapping.** Decides which resource and action a controller action belongs to. Returns `[resource, key]`, `false` (never managed) or `nil` (use the convention); anything else, or a name that is not valid, raises `PermissionForge::ConfigurationError`.

#### controller_discovery_exclude

**Controllers left out.** Controllers that are never listed or checked: Regexps, or Strings naming a controller or a namespace (`'webhooks'` covers `webhooks` and `webhooks/*`). Blank entries are ignored. PermissionForge's own controllers are always left out.

#### unconfigured_action_strategy

**Actions without a setting.** What happens to a controller action that no Permission Set mentions: `:allow` (default) or `:block`.

#### action_guard_bypass

**Who skips the action check.** People for whom controller actions are never checked, for example administrators.

#### action_guard_nil_user_strategy

**Action check with nobody signed in.** What the guard does with a mapped action when there is no current user. `nil` or blank (the default) follows `nil_user_strategy`; `:bypass` lets the request through; `:deny` refuses it (`ActionNotAuthorizedError`), and so do `:raise` and unknown values. The generated initializer sets `:deny` for new installs; existing installs keep following `nil_user_strategy` until they set it.

### Activation conditions

#### request_context_resolver

**Request details source.** Where IP address, time and session flags come from. Called on every permission read of a user who holds a conditional set (never for other users): keep it cheap, return `{}` (or anything with `#to_h`) outside a request, and never read permissions inside it, which raises `PermissionForge::ConfigurationError`.

#### conditional_sets_strict_mode

**Strict activation conditions.** With no request context (the resolver returns nothing, or neither an IP nor session flags), strict mode drops conditional granting sets and keeps conditional muting sets. Without it, a blank context lets every conditional set count. See [Activation Conditions](activation-conditions.md#strict-mode).

### Privacy (GDPR)

#### gdpr_defaults

**Privacy defaults.** Columns that look personal get masked by default when they're added.

#### gdpr_require_explicit_choice

**Require a privacy-defaults choice.** The app refuses to boot until privacy defaults are switched on or off explicitly.

#### gdpr_field_patterns

**Sensitive name patterns.** Column names matching a pattern are flagged sensitive and get this mask style.

#### filter_parameters_integration

**Filter sensitive values from logs.** Adds the privacy patterns to Rails' filter_parameters so logs don't show them. The patterns also reach `ActiveRecord::Base.filter_attributes` (Rails copies `config.filter_parameters` there), so a matching attribute (`name` and `email` included) prints as `[FILTERED]` in `#inspect`, `pretty_print` and error reports.

### Caching

#### cache_backend

**Cache store.** Where computed permissions are cached.

On Rails 7.1 and 7.2 with connection_pool 3.x, `ActiveSupport::Cache::RedisCacheStore.new(url: …)` raises `ArgumentError` when it builds its connection pool (a Rails/connection_pool incompatibility, not PermissionForge's). Pin `connection_pool` below 3, or pass `pool: false`, until you upgrade Rails.

#### cache_key_prefix

**Cache key prefix.** Prefix for every cache entry.

#### cache_ttl

**Cache lifetime.** How long computed permissions are kept. A new value applies to entries cached after the change; entries already in the store keep the TTL they were written with.

#### conditional_set_cache_ttl

**Conditional set cache lifetime.** How long permissions are kept for people with conditional sets: the base entry and its per-context variants. Selection happens on every read; this is a backstop. It is also how long the variants an invalidation leaves stay in the store (unreachable); with this and `cache_ttl` both `nil` they stay until written over, an erasure or `cache:clear`.

#### snapshot_transactions

**Transactions read from a snapshot.** Whether a database transaction keeps seeing the data as it was when it began. Permissions computed inside such a transaction are not cached. Auto decides from the database: MySQL and SQLite do, PostgreSQL only at repeatable read or stronger.

#### on_cache_failure

**When the cache store fails.** Code that runs when cached permissions could not be cleared, for example to alert you. Until the cache lifetime ends, that person may keep their old permissions.

### Audit log

The audit event log is described in [audit-log.md](audit-log.md); these are its options.

A value the log cannot work with is refused with `PermissionForge::ConfigurationError` when it is set (at configure time): `audit_events` other than `:auto`, `true` or `false` (a string from `ENV` is refused, not read as `:auto`), a failure strategy that is not one of its values, an `audit_runtime_events` group that is not one of `denied bypass field_read params_filtered cache`, and an `audit_retention_period` that is not a positive Duration, a positive number of seconds or `nil`.

#### audit_trail_enabled

**Record who created and last edited.** Stamps them on the 8 permission models when the acting person is a record of `audit_user_class`; API clients, HTTP Basic logins, system and Hash actors stamp nothing and leave the previous editor. A convenience on the live row, not the audit log.

#### audit_user_class

**Audit people model.** The model used for “created by” and “edited by”.

#### audit_events

**Audit log.** Records each change made through the permission models — the actor as resolved (possibly `unknown`), when, and the previous values — in the `audit_events` table. `:auto` (default): on when the table exists. `true`: always (under the default `:raise` strategy a missing table then fails every change). `false`: never (events are still published).

#### audit_actor_resolver

**Who is recorded as the actor.** Code that names who acts in a request to these screens or the API. Not set means the signed-in person; under HTTP Basic, the username.

#### audit_request_context

**Request details on events.** Code that gives the request id and IP address stored with each event. Not set means `request.request_id` and `request.remote_ip`.

#### audit_change_failure_strategy

**When a change cannot be recorded.** `:raise` (default) rolls the change back; `:report` lets it through and reports it; `:log` lets it through and only logs it. This covers every event written with `Audit.record`; a refusal written after an open transaction and the events of a rake report are reported, never raised, and the purge always fails closed.

#### audit_hook_failure_strategy

**When a subscriber fails.** What happens when a subscriber, legacy hook, runtime-event store or resolver fails: `:report` (default), `:log` or `:raise`.

#### audit_runtime_events

**Stored runtime events.** Which runtime decisions are stored, not only published: `denied` (default), `bypass`, `field_read`, `params_filtered`, `cache`.

#### audit_log_subscriber

**Copy events to the log.** Also writes every audit event, with its data but without name labels, to the application log.

#### audit_retention_period

**Keep audit events for.** How long audit events are kept before the purge task may delete them. Not set means forever.

#### audit_log_authorization

**Who may read the audit log.** Code that decides who may read the audit log, its exports and the API endpoint; allowed only when it returns exactly `true`. Not set means anyone with access to these screens.

### Multi-tenancy

#### tenant_model

**Tenant model.** Model that separates customers of a multi-tenant app.

#### tenant_column

**Tenant column.** Column that holds the tenant on each record.

#### admin_tenantless_access

**Admin requests with no tenant.** What the admin screens and the admin API do with a request that has no current tenant while `tenant_model` is set. `:deny` (default) refuses it with a 403, recorded as `admin.auth_failed` / `api.auth_failed` with reason `tenant_missing`. `:allow` serves it: it reads, edits and deletes existing records of **every** tenant, but creating a record still needs a tenant (refused as invalid, 422 in the API). Only the exact `:allow` (or `'allow'`) allows; anything else denies. Set the tenant in `base_controller_class` / `api_base_controller_class` (or middleware) instead — see [multi-tenancy.md](multi-tenancy.md).

### Admin JSON API

#### api_enabled

**JSON API.** Lets other systems manage Permission Sets over HTTP.

#### api_auth

**API sign-in.** How API callers prove who they are.

#### api_base_controller_class

**API controller.** The controller API endpoints inherit from.

#### api_action_authorization

**API permission check.** Decides which API calls each caller may make.

#### api_assignment_authorization

**API assignment check.** Decides who may assign Permission Sets through the API. Called with `(controller, target, user_ids)`: `target` is the `PermissionSet`, or the `PermissionSetGroup` on the group-member endpoints; `user_ids` is an Array cast to the user model's key type (Integers for integer keys) on every endpoint. A truthy answer allows.

#### api_require_authorization

**Require API permission checks.** Default `true`: until `api_action_authorization` and `api_assignment_authorization` are both set, API changes and assignments are refused (403, `api.auth_failed`). `false` lets every caller `api_auth` admits change permissions and assign anyone (boot warning; `rake permission_forge:audit` finding `api_mutations_unguarded`).

#### api_stats_require_admin

**Stats only for admins.** Only admins can read usage statistics through the API.

#### api_record_identifier

**API record identifier.** Which identifier the API uses in URLs.

#### api_default_per_page

**Default page size.** Records per API page when the caller doesn't say.

#### api_max_per_page

**Maximum page size.** Upper limit on records per API page.

#### api_pagination_handler

**Pagination.** How API results are split into pages.

#### api_serializer_overrides

**Custom serializers.** Overrides for how records are written in API responses.

#### api_redact_rule_field_values

**Hide rule values in the API.** Rule values are redacted in API responses.

### Admin screens

#### admin_model_resolver

**Models offered in the admin.** Which models are offered when you add a resource.

#### admin_session_flags

**Session flag names.** Friendly names for session flags offered on the Conditions tab.

#### admin_stale_assignment_days

**Review assignments after.** Permanent assignments not reviewed for this long appear under Stale assignments. Also the default threshold of `rake permission_forge:stale_assignments` and `StaleAssignmentAuditor`.

#### admin_app_name

**App name.** The app name shown under the logo in these screens.

#### admin_back_url

**"Back to app" link.** Where the link under the logo leads (default: your app's home page). A String, or a lambda receiving the view context, e.g. `->(view) { view.main_app.dashboard_path }`.

#### admin_docs_url

**Configuration docs link.** Where the “Configuration docs” links on this page point to.

### Database & system

#### table_name_prefix

**Table prefix.** Prefix for PermissionForge's own database tables.

#### uuid_generator

**UUID generator.** How record UUIDs are created.

#### available_locales

**Languages.** Languages these screens are available in.
