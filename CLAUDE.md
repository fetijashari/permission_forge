# PermissionForge — Claude Code Instructions

## Project

Ruby gem (Rails Engine) implementing a 3-tier permissions system: Resource CRUD > Field-level read/edit > Row-level query rules.
Ruby >= 3.2, Rails >= 7.1, SQLite for tests. MIT license.

---

## Commands

```bash
bundle install                    # Install dependencies
bundle exec rake test             # Run full test suite (~4,460 tests; SQLite runs in 8 forked workers, PARALLEL_WORKERS=1 for serial)
bundle exec ruby -Itest -e 'Dir["test/permission_forge/models/**/*_test.rb"].each { |f| require File.expand_path(f) }'    # Model tests only
bundle exec ruby -Itest -e 'Dir["test/permission_forge/services/**/*_test.rb"].each { |f| require File.expand_path(f) }'  # Service tests only
bundle exec rubocop --parallel    # Lint
bundle exec ruby -Itest test/permission_forge/table_name_prefix_test.rb  # Table prefix tests
bundle exec ruby -Itest test/permission_forge/rails_internals_canary_test.rb  # Rails-internals canary (run first after a Rails upgrade)
BUNDLE_GEMFILE=gemfiles/rails_main.gemfile bundle exec ruby -Itest -e 'require "test_helper"; SimpleCov.minimum_coverage(0); require "./test/permission_forge/rails_internals_canary_test.rb"'  # canary on Rails main
bundle exec rake yard:check       # Public API docs floor (CI)
```

---

## Architecture

### Directory Map

| Layer | Path | Purpose |
|-------|------|---------|
| Entry point | `lib/permission_forge.rb` | `configure`, `current_user`, `cache`, `table_name_prefix`, `gdpr_filter_parameters`, `MODEL_NAMES` (the nine models), `RESOURCE_NAME_FORMAT`, `const_missing` (explains a model referenced before the app's autoloader exists); `ModelBindings` (`model_bindings.rb`: what a loaded model declared vs the configuration; logged by `configure` and after boot) |
| Configuration | `lib/permission_forge/configuration.rb` | All config options, defaults, cache store builder; sub-settings in `configuration/` (`GdprSettings`, `MaskedAttributesSettings`, `QueryScopingSettings`, `AdminUiSettings`, `VirtualAttributesSettings`, `ControllerActionSettings`, `CacheSettings`, `AuditSettings`, `PermitsAttributesSettings`; `MaskedAttributesSettings` also holds `masked_attributes_nil_user_strategy`); `Presets` (`config.preset`: `:compat` = library defaults, `:strict`; a defaults layer: each preset option's writer records an explicit setting, which always wins; `OPT_IN` = checklist rows in no preset), `StrategyValues` (prepended: every strategy option takes a Symbol from its list or its String, anything else raises `ConfigurationError`) |
| Engine | `lib/permission_forge/engine.rb` | Rails::Engine, isolated namespace — initializers and hooks only; the work lives in plain modules (`BootChecks`, `MaskingSync`, `MaskedModels`, `QueryScopingWarnings`, `Audit`, `ExecutionState`). Never extend a module into the Engine or call `Engine.send`. `Engine.apply_masked_attributes_to_managed_models` is a deprecated delegator to `MaskedModels.apply` (removed in 0.15) |
| Boot & masking | `lib/permission_forge/boot_checks.rb`, `masking_sync.rb`, `masked_models.rb`, `query_scoping_warnings.rb` | `BootChecks.run` (config warnings, then `DATABASE_STEPS`: an ordered table, each step skipped when the database is unreachable), `BootChecks.ensure_tenancy_gem!`; `MaskedModels` (`apply(only:)`, `apply_concern`, `enabled?`, `row_driven?`: a setting that takes its models from the Resource rows); `MaskingSync` (`check!`, `named!`, `boot!`, `reloaded!`) |
| Execution state | `lib/permission_forge/execution_state.rb` | `ExecutionState` — the one place for the gem's per-fiber / per-request state; `KEYS` lists every slot: its scope (`:fiber` = `Thread#[]`, for the slots whose leak would widen access or drop audit events; `:execution` = `ActiveSupport::IsolatedExecutionState`), what the end of an executor run does (`:clean` = remove what the run added, never write; `:keep`) and what it holds; `RunHook` is installed by `Audit.install!` |
| Deprecations | `lib/permission_forge/deprecation.rb` | `PermissionForge.deprecator` (registered with `Rails.application.deprecators` via `on_load(:before_initialize)`), `Deprecation.warn` (once per key), `HORIZON` |
| Conditional sets | `lib/permission_forge/conditional_sets.rb` | `ConditionalSets` (Data: sets, token): a user's conditional sets as kept in the base entry; `.no_context?` (strict mode), variant slots (`<key>_c_<1..63>`, the bitmask of the selected sets; the stored variant carries `variant_of`, checked on every read: `.variant_hash`), the index entry (`<key>_c_index`: `true`, written before a variant is stored; read only by the enumerated `cache:clear`), `MAX_CACHED_SETS = 6` (above: variants built per request, never cached) |
| Masking sync | `lib/permission_forge/masking_sync.rb` | `MaskingSync`: token `masked_models_version` in the cache store, read and written only while a masking setting is `:auto` (`MaskedModels.row_driven?`); `check!` on the executor's `to_run` (one store read per request/job under `:auto`, none with lists or `false`), `named!`/`apply!` from `Resource` after commit, `boot!`, `reloaded!` on `to_prepare` |
| Resource chain | `lib/permission_forge/resource_chain.rb` | `ResourceChain`: the Resource names a class answers to (own name + STI ancestors on the same table), the rules of every entry (`rules`), the strictest field entry (`field_permissions`, `fields`) |
| Cache | `lib/permission_forge/cache/` | `Base` interface (`read_fresh`, `expunge`), `MemoryCache`, `NullCache`, `RailsCache` (`write_many` / `expunge_many` / `delete_many` on `Base`; defaults loop); `UserKeys` (the one definition of a user's keys: `v2:` namespace, the previous namespace removed until 0.15, variants, the stamp; `entry_patterns` / `canary_keys` for a removal by pattern), `Base#read_many` / `#clear_entries` (canary-verified) / `#purge_entries`, `HolderInvalidation` (holders by id, slices of 500) + `BulkInvalidation` (one multi-key stamp write + one removal per slice; `.unconfirmed` is the one rescue), `VariantRemoval` (per-context variants: index entry + every slot; erasure without reading, the enumerated clear through the index entries); `Invalidation` (stamp, verified removal, retries) with `Backlog` (invalidations this process still owes the store), `Rebuild` (store, then verify against the stamp; `withhold`), `Settlement` (invalidate again after the commit), `Failure` (report, never raise; `Failure.none? { }`, `Failure.collect { }`), `HandledErrors` (a batch counts as written only when the store handed its `error_handler` no error during the call: Rails 8.2's Redis store answers the same either way), `WithheldNotice` |
| Transactions | `lib/permission_forge/open_transaction.rb` | `OpenTransaction.current` (a joinable transaction is on the connection's stack; a sandbox console counts) and `.withholding` (it reads from a snapshot per `config.snapshot_transactions`, or is the sandbox); `#finished?`, `#rolled_back?`, `#after_commit` — read off the adapter's transaction objects on every Rails version |
| Concerns | `lib/permission_forge/concerns/` | `RecordsAuditEvents` (included in all 8 models: the change events + `audit_as`), `PermissionedUser` (composition), `PermissionCacheAccessor` (+ `PermissionsMemo` with `PermissionsMemo::Memo`, + `PermissionsPerContext`: per-read selection of the base entry or a conditional-set variant), `ResourcePermissionChecker`, `FieldMaskChecker`, `MaskedAttributes` (+ `masked_attributes/virtual_readers.rb`, `store_access.rb`, `alias_access.rb`, `validation_reads.rb`: validators read the stored value of the attribute they validate), `PermissionScopedFindable`, `PermissionsRegenerator`, `InvalidatesManagedActions`, `ControllerActionGuard` (host controllers), `HasPermissionSetUsers`, `HasActiveScope`, `HasTenantScoping`, `ValidatesDependency`, `HasUuid`, `HasAuditTrail`, `InvalidatesInBatch` (+ `lib/permission_forge/invalidation_batch.rb`; `note_previous_value` keeps every previous owner until a commit), `ValidatesColumnLengths` (a string longer than its column's declared limit is a validation error) |
| Controller actions | `lib/permission_forge/controller_actions/` | `Mapping` (controller action → Resource + key), `ManagedIndex` (what any set manages), `Authorizer` (the guard's decision); constants and declaration helpers in `controller_actions.rb` |
| Virtual fields | `lib/permission_forge/virtual_fields.rb` | `VirtualFields` — the one reader of `extra_fields_method` (declared, discovered, implicit-grant names); `VirtualFields::Discovery` |
| Models | `app/models/permission_forge/` | 8 AR models with dynamic `self.table_name` methods, plus the insert-only `AuditEvent` (a 9th table; `AuditEvent.tenant_column` / `.in_tenant(id)` scope the erasure scrub and the purge) — autoloaded by the host application (Zeitwerk), never required by the gem; a class body reads the configuration after `config/initializers` |
| Audit log | `lib/permission_forge/audit.rb`, `lib/permission_forge/audit/` | `Audit.record` (change/admin/system events) and `Audit.instrument` (runtime events) are the one emitter; `EventCatalog` (registry), `Recorder` (builds an event once), `ColumnValues` (cleans string columns), `Context` / `Actor` / `Source` / `ActorResolver` / `RequestContext` (who, where, why), `Detached` (refusals written after the transaction ends), `Failure`, `Gate` / `Runtime` / `RuntimeEmission` / `FieldAccess` (runtime events), `Subscribers` (+ `subscribers/`: log, legacy hooks), `AuditedViews` (pages whose viewing is an event), `EventQuery` (filters shared by page and API), `LogAccess`, `Refusals`, `BootWarnings`, `SettingsObserver`, `JobContext`; options in `configuration/audit_settings.rb`; `lib/permission_forge/rake_audit.rb` (ACTOR=/REASON=, `report.generated`) |
| Services | `lib/permission_forge/services/` | `PermissionHashBuilder`, `FieldPermissionMerger`, `PermissionRuleApplier`, `PermitsAttributes`, `FiltersResponseAttributes`, `AttributeAccessGuard`, `ResourceFieldGenerator`, `MaskValue`, `GdprFieldAuditor`, `ConsentWithdrawalHandler`, `DataSubjectErasure`, `StaleAssignmentAuditor`, `BulkPermissionSetAssignment`, `PermissionCacheClearer` (`rake permission_forge:cache:clear`: every user's entries by key pattern or by enumeration; `cache.cleared` per tenant + one tenant-less), `ExpiredAssignmentCleaner`, `AuditEventPurger`, `PermissionSetConditionEvaluator`, `PermissionSetCloner`, `PermissionSetGroupCloner`, `ResourceWithFieldsBuilder`, `DashboardStats`, `ExtraFieldDefaults`, `HostKeyGuard`, `SecurityAudit` (+ `security_audit/` checks, among them `user_model_check.rb`); `permits_attributes/nested_records.rb` (`PermitsAttributes::NestedRecords`: a nested `id` must be in the child's `permission_scoped`) |
| Service Concerns | `lib/permission_forge/services/concerns/` | `Clonable` — shared clone/duplicate logic; `AcrossTenants` (`across_tenants`: a tenant-less maintenance run lifts acts_as_tenant's scope, also under `require_tenant`; `record_per_tenant`: one summary event per tenant concerned plus one without a tenant) |
| Operators | `lib/permission_forge/operators/` | `Registry` (strategy pattern), `Constants`, `Validations` (+ `VALUELESS` / `.valueless?`: operators that take no value), `ValueTyping` (+ `ValueCasters`, `value_casters/number.rb`, `value_casters/temporal.rb`), `RuleColumn` |
| API Concerns | `app/controllers/concerns/permission_forge/api/` | `ResponseRenderer`, `Pagination`, `SerializerResolver`, `CrudActions`, `NestedResourceLookup` |
| Admin read models | `lib/permission_forge/admin/` | `AuditLog` (+ `AuditLogDays`, `AuditLookups`, `LastChanges`), `Csv` (the one CSV writer), `Exports` (`Events`, `Holdings`, `Document`), `EffectiveAccess` (provenance, parity-tested vs `PermissionHashBuilder`), `ChangeSet` (batched edits + cascades), `AttentionItems`, `SettingsCatalog`, `ModelCatalog`, `FieldRows`, `ControllerCatalog` (host routes → mapped actions), `ActionRows`, `ActionAcrossSets`, `RuleForm`, `AuditTrail`, `PeopleDirectory` (`#find` / `#find_all`: people by id within `user_list_resolver`), `PersonLabel`, `SensitiveColumns`, `ExpiryPresets`, `BulkPeopleMatcher`, `FieldLevel`, `FieldDetail` / `AuditEventDetail` / `RuleBuilder` (the logic of the heaviest pages; templates only draw them), `EditableLock` (the `is_editable` chain: record → Resource → Permission Set, membership → group; `widens_expiry?`), `PermissionSetFactory` (create, duplicate, editable clones), `RecordId` |
| Admin helpers | `app/helpers/permission_forge/` | `ApplicationHelper` includes `UiHelper` (components), `SentencesHelper` (rule/condition/change sentences), `AuditHelper`, `SettingsHelper` |
| Shared partials | `app/views/permission_forge/shared/` | `_sheet_frame`/`_dialog_frame` (via `pf_sheet_frame`/`pf_dialog_frame` — never `render layout:`, it breaks lazy `t('.x')`), `_crud_cell`, `_level_control`, `_expiry_picker`, `_savebar`, `_mode_banners`, `_across_sets`, `_audit_footer`, `_tech_details`, `_help_banner`, `_toasts`, `_head_extra` (host theming hook) |
| Admin assets | `app/frontend/permission_forge/` | `pf_admin.css` (tokens + components), `pf_admin.js` (progressive enhancement), `brand/` — served by `AssetsController`, NOT the host asset pipeline |
| API Controllers | `app/controllers/permission_forge/api/` | 9 JSON API controllers (dashboard, permission_sets, resources, fields, actions, rules, users, groups, group_users) plus the read-only `audit_events` |
| API Serializers | `lib/permission_forge/api/serializers/` | 10 lightweight Ruby serializers plus `BaseSerializer` (no AMS dependency) |
| API Auth | `app/controllers/concerns/permission_forge/api_authentication.rb` | `verify_api_enabled!` + `authenticate_api_request!` |
| HTML Controllers | `app/controllers/permission_forge/` | `concerns/permission_forge/cache_confirmation.rb` (`CacheConfirmation`: flash what the cache store confirmed). Admin screens: `Home`, `People`, `Assignments`, `BulkAssignments`, `PermissionSets`, `Resources`, `ResourceFields`, `ResourceActions`, `PermissionSetRules`, `PermissionSetGroups`(+`GroupUsers`), `FieldLookups`, `Settings`, `Preferences`, `Maintenance`, `Assets`, `AuditEvents` (the log, exports, holdings); concerns `AuditLogGate` (`audit_log_authorization`), `AssignmentAuthorization` (`admin_assignment_authorization`), `ActingAdmin`, `TenantRequired` (403 with no tenant while `tenant_model` is set, unless `admin_tenantless_access = :allow`; admin and API), `ParamShapes` (`pf_require_hash`, `pf_hash_param`, `pf_text_param`, ...: the shape of every param, NUL bytes dropped; admin and API), `HtmlFormat` (the admin answers HTML whatever the `Accept` header; exports declared with `pf_exports`), `ForgeryProtection` (`protect_from_forgery with: …, **pf_forgery_strategy`: every engine controller verifies with `:header_or_legacy_token` on Rails 8.2+, whatever the host chose) |
| I18n / Locales | `config/locales/` | 3 locale files (en, sq, mk), `i18n-tasks.yml` config |
| Generators | `lib/generators/permission_forge/` | `install` (initializer + migration; user and tenant key columns typed from the host models, `--user-id-type` / `--tenant-id-type`), `upgrade` (three migrations for existing installs: resource-field unique index + de-dup, admin-UI columns, audit log; `--skip`, `--tenant-column`), `rls` (PostgreSQL Row-Level Security policies) |
| Docs | `docs/` | Junior-friendly how-to guides (`docs/configuration.md` holds the full option reference and the Presets section); `docs/audit-log.md` is the audit log's source of truth |
| Tests | `test/` | Minitest + custom helpers, dummy Rails app in `test/dummy/`; `test/support/` (`configuration_snapshot.rb`, `parallel_workers.rb`, `method_stubs.rb`, `test_models.rb`, `local_redis.rb` (`require_local_redis!`, `PF_TEST_REDIS_URL`), ...) |

### Host App User Model Contract

The host app's User model needs SOMETHING the gem can use to show people in the admin (People list, person pickers, audit). Either of these works (no User model changes required for most apps):

- A `:name` method/column (recommended — typically `"#{first_name} #{last_name}"`), and/or
- An `:email` method/column, and/or
- `:full_name` / `:display_name` / `:first_name` + `:last_name` / `:firstname` + `:lastname` (auto-discovered)

Labels come from `Admin::PersonLabel`: `config.user_label_formatter` if set, else `:name` → `:full_name` → `:display_name` → composed first/last name → `:email` → `User #<id>`. Attribute reads go raw-column-first (`read_attribute_before_type_cast`) to bypass MaskedAttributes; the public reader is only consulted for virtual attributes or blank columns.

For full control, configure `config.user_label_formatter`:
```ruby
config.user_label_formatter = ->(u) { "#{u.last_name}, #{u.first_name} <#{u.email}>" }
```

The candidate list is built from `config.user_list_resolver` (default `user_model.order(:id)`, schema-agnostic). Search (`Admin::PeopleCandidates`) runs in SQL on whichever of `name email full_name display_name first_name last_name firstname lastname username login` exist; every query word must match some column, so split name columns work. Array-returning resolvers are searched in Ruby by label. Pickers are capped by `config.user_list_limit` (default 500; `nil` disables). The group "Add member" control is still a plain `<select>` (`shared/_user_select`, labels via `pf_user_option_label` with `#<id>`), with a localized hint when the cap trims it.

### Key Design Decisions

- **All integration points use lambdas** — zero hard deps on Current, Rolify, Pundit, Devise
- **Dynamic `self.table_name` methods** (not `self.table_name =`) — evaluated lazily so `table_name_prefix` config works at runtime and test time. Default prefix: `permission_forge_`. Generator accepts `--table-prefix` for custom/empty prefix. Tests use `''` for simplicity.
- **The models are autoloaded, not required** — `app/models/permission_forge/`; `belongs_to :user`, `created_by`/`updated_by` and `apply_tenant_scoping!` read the configuration as the class loads (after the host's initializers, again after a dev reload). Nothing in `lib/` may reference a model constant at require time (a constant, a class body) and no engine initializer may reference one — the application's autoloader is set up after every initializer (Rails 7.1+); `after_initialize`/`to_prepare`/method bodies are fine. `PermissionForge::MODEL_NAMES` is the list; `PermissionForge.const_missing` explains a too-early reference. Because the gem no longer loads `ActiveRecord::Base` at require time, `config.active_record.*` in a host initializer applies and `config.filter_parameters` reaches `filter_attributes` (`[FILTERED]` in `inspect`)
- **Explicit masking costs nothing per request** — `MaskingSync` reads and writes its cache-store token only while a masking setting is `:auto` (`MaskedModels.row_driven?`); with lists it syncs once per process (and after a reload), and with both settings off `check!` reads nothing (the executor hook is always installed: a setting may be switched on after the boot step). The recommended production setup is `include MaskedAttributes` in the model plus `auto_apply_masked_attributes = false`. Under `:auto` the read stays even when every named model includes the concern (a later row may name one that does not)
- **Presets are a defaults layer** — `config.preset = :strict` fills only the options nobody set; library defaults never change silently (`:compat` is pinned to `Configuration.new`). New installs get the safe subset explicitly from the generator and `# config.preset = :strict` commented; the generated initializer stays under 150 lines (a test pins it) and every option it leaves out is documented in `docs/configuration.md`
- **Cache wraps `ActiveSupport::Cache::Store`** — supports Redis, SolidCache, Memcached, file, memory, null
- **Invalidate, don't eagerly rebuild** — permission/assignment changes invalidate affected users' cached hashes; `permissions_hash` is read-through (a miss rebuilds in the current request). Invalidation is coalesced per transaction (`InvalidationBatch`: each user once per commit; a batch only remembers what was already done after the commit, so losing one costs repeats, never a miss). Every invalidation writes a per-user stamp before deleting; a rebuild reads its rows uncached and re-checks the stamp (`Cache#read_fresh`, past the store's local cache) so a hash built across an invalidation is never left in the cache. The holders of a changed set are invalidated by id, in slices of 500 (`Cache::HolderInvalidation`), except when the user model overrides `invalidate_permissions` / `permission_cache_key`, something subscribes to `permissions.invalidated`, or a snapshot transaction withholds — then per user. `cache_ttl` default 3600s, clamped to `conditional_set_cache_ttl` (300s) for conditional sets and to the soonest assignment `expires_at` The users to invalidate are looked up in the changed record's tenant, not the ambient one (`HasTenantScoping.of_tenant`)
- **Conditional sets are selected per read** — the cached base entry holds the unconditional sets plus the user's conditional sets and their conditions; each read evaluates the current request context (`request_context_resolver`, which must never read its own user's permissions — that raises `ConfigurationError`) and serves the base or a variant in the slot of the passing set ids, verified against the same stamp when stored and against the base entry's token on every read (`variant_of`). An invalidation removes the base entry only — the variants become unreachable and expire with `conditional_set_cache_ttl` — and only `DataSubjectErasure` and `cache:clear` remove variants (`Cache::VariantRemoval`). Strict mode without a request context drops conditional granting sets and keeps conditional muting sets. A user without conditional sets pays nothing extra
- **`permissions_hash` is memoized per user instance** — one store read per request instead of one per attribute check. Retired by `PermissionForge.permissions_cache_version` bumps (every `invalidate_permissions`/`regenerate_permissions`/cache-store swap bumps; never delete cache keys directly — route through `invalidate_permissions`), by `#reload`, and by a tenant cache-key change. The memo is a shared object: callers treat it as read-only. After a rebuild the instance keeps the hash it built (it is not read back from the store). A hash withheld inside a transaction is also retired by the end of that transaction or a rollback to a savepoint, and every memo at the soonest assignment `expires_at` that went into it (`assignments_expire_at` in the base entry, never in `permissions_hash`) (`PermissionsMemo`)
- **A transaction is only special where it reads from a snapshot** — `config.snapshot_transactions` (`:auto` = MySQL and SQLite always, PostgreSQL only inside an explicit `repeatable_read`/`serializable`). There a rebuild is withheld from the cache and kept on the instance, which does not read the store again until the outermost transaction ends, and `regenerate_permissions` / `invalidate_permissions` are settled by an `invalidate_permissions` after the commit (`Cache::Settlement`). Everywhere else (PostgreSQL at READ COMMITTED) a transaction changes nothing — keep it that way: a rolled-back grant that was regenerated inside the transaction stays cached there, as documented
- **The managed-actions index is never written to the store from inside an open transaction**, whatever the setting — uncommitted rows are visible to their own transaction at every isolation level
- **The store's answers are checked and nothing raises out of an after-commit invalidation** — remove with `cache.expunge`, never a bare `delete`; a failed invalidation is retried, reported through `Cache::Failure` (log, `cache_failure.permission_forge`, `config.on_cache_failure`) and kept as owed in the process (`Cache::Backlog`, best effort, `cache_ttl` is the backstop). A dead store never yields an empty hash: the request uses the hash it built
- **`PermissionScopedFindable`** overrides `find_by`/`find_by!` and adds `Model.permission_scoped` — nil `current_user` behavior follows `nil_user_strategy` (default `:bypass`)
- **Controller actions reuse `ResourceAction`** — no new table and no new hash key. An action is *managed* once a row for it is in effect (`ResourceAction.in_effect`: active row, active resource, active set); unmanaged actions follow `unconfigured_action_strategy` (default `:allow`). Controllers with no model are out of scope: never create a `Resource` row whose name is not a model (the tables are shared with a host whose legacy generator constantizes every name)
- **Every change is an audit event, written in the change's transaction** — `RecordsAuditEvents` (`after_create/update/destroy`, not `after_commit`) calls `Audit.record`; with `audit_change_failure_strategy = :raise` (default) a change whose event cannot be written rolls back, also for a caller that rescues the error (`OpenTransaction#before_commit`). Every store runs in a savepoint (a failed INSERT must not abort a PostgreSQL transaction). `audit_events = :auto` records when the table exists; a missing table never breaks a change. Runtime events (`Audit.instrument`) never break the request (unless `audit_hook_failure_strategy = :raise`) and cost nothing when nobody listens and the group is not stored (`Audit::Gate`). `audit_runtime_events` is frozen
- **Permission hash format is a public contract** — `{ profile:, preferences:, permissions: { resources: { ModelName: { permissions:, fields:, actions:, source_permission_sets:, permission_set_rules: } } } }`

---

## Models (8 total, plus `AuditEvent`)

| Model | Table (with default prefix) | Purpose |
|-------|----------------------------|---------|
| `PermissionSet` | `permission_forge_permission_sets` | Groups of permissions, `active`/`inactive`, `is_muting` for subtractive sets, activation conditions (`requires_session_flag`, `allowed_ips`, `allowed_hours_start/end`) |
| `PermissionSetUser` | `permission_forge_permission_set_users` | User ↔ PermissionSet join, `expires_at` for time-bound assignments, unique per (user, set) |
| `PermissionSetGroup` | `permission_forge_permission_set_groups` | Optional grouping of sets |
| `PermissionSetGroupUser` | `permission_forge_permission_set_group_users` | User ↔ Group join, unique per (user, group) |
| `Resource` | `permission_forge_resources` | Entity-level CRUD access, `name` validated as a Ruby constant path |
| `ResourceField` | `permission_forge_resource_fields` | Column-level read/edit access + mask_access/mask_strategy, unique per (resource, name) — DB index + validation |
| `ResourceAction` | `permission_forge_resource_actions` | Admin-defined custom actions per resource (e.g., sync, export) |
| `PermissionSetRule` | `permission_forge_permission_set_rules` | Row-level query rules (15 operators, 3 join types) |
| `AuditEvent` | `permission_forge_audit_events` | The audit event log: insert-only through the model (not one of the 8 permission models; no `HasAuditTrail`, no cache invalidation) |

---

## Concerns

### PermissionedUser (include on User model)
Composition concern that includes 3 focused sub-concerns:
- **PermissionCacheAccessor** — `permissions_hash` (read-through — cache miss rebuilds), `regenerate_permissions`, `invalidate_permissions(tenant_id:)`, shared hash navigation helpers
- **ResourcePermissionChecker** — `can_read?/create?/edit?/delete?(resource)`, `can?(action, resource)`, `permissions_for`, `permissions_hash_for`, `can_view_all?`, `can_modify_all?`, aliases
- **FieldMaskChecker** — `masked_field?(resource, field_name)`, `mask_strategy_for(resource, field_name)`, `field_permissions(resource, field_name)`

### PermissionScopedFindable (include on protected models)
- Thin orchestrator — overrides `find_by`/`find_by!` and adds `Model.permission_scoped` (chainable rule-constrained relation), delegates query building to `PermissionRuleApplier` service
- `find_by` returns `nil` for a genuinely missing record; `NotAuthorizedError` raised only when a rule denies an existing record
- ViewAll/ModifyAll bypass — when resource has `view_all` or `modify_all`, all row-level rules are skipped
- Nil current user follows `nil_user_strategy` (default `:bypass`); fallback queries use `where(nil)` (preserves `default_scope` and tenant scope)

### PermissionsRegenerator (included on PermissionSet, Resource, ResourceField, ResourceAction, PermissionSetRule, PermissionSetGroup)
- `after_commit` on create/update/destroy invalidates affected users' cached permissions (lazy read-through rebuild — no eager regeneration)
- Runs through `InvalidatesInBatch` (one `after_commit :invalidate_after_commit` per record; concerns add steps by overriding `invalidate_committed_caches` and calling `super`). The record joins its transaction's `InvalidationBatch` in `before_save`/`before_destroy` and claims it in `after_commit`; `touch` and anything without a batch invalidates on its own. Never make a batch hold pending work
- `PermissionSetUser` invalidates its own user via its own `after_commit` — assignment/revocation takes effect immediately
- Each model defines `users_on_permission_set` to resolve affected PermissionSetUser records
- Uses direct DB queries (not cached associations) to avoid stale data in callbacks

### ControllerActionGuard (include on host controllers)
- `before_action :pf_authorize_action!` → `ControllerActions::Authorizer` → raises `PermissionForge::ActionNotAuthorizedError` (`resource`, `action`, `controller_path`, `reason`); never renders
- `permission_forge_actions resource:, actions:, rest_actions:` declares the mapping; repeated and subclass declarations **add to** the current one; invalid names raise `ArgumentError` at class load
- Decision order: unmapped → allow; nil user → `nil_user_strategy`; `action_guard_bypass`; a grant (`user.can?`) → allow; then one `ManagedIndex` lookup: unmanaged → `unconfigured_action_strategy`, managed → deny
- Anything unexpected fails closed: resolver typos and wrong-shape answers raise `ConfigurationError`, a model that fails to load raises, a raising bypass counts as no bypass, only an exact `true` grants

### InvalidatesManagedActions (included on PermissionSet, Resource, ResourceAction)
- Drops `ManagedIndex` when a row that counts is created, destroyed, renamed, or switched on/off. The change is noted in `after_save` and consumed in `after_commit` — `after_commit` alone only sees the last save of a transaction

### MaskedAttributes (include on protected models, or auto-applied)
- Enforces field-level read permissions on the model itself — overrides `read_attribute`, `attributes`, per-column getters, and `*_for_serialization` (covers getters, `[]`, `as_json`, `to_json`, AMS, Jbuilder)
- Auto-applied to models with a matching `Resource` row per `config.auto_apply_masked_attributes` (default `:auto`)
- Write-back protection via `config.masked_write_protection` (default `:skip`) — masked/hidden values can't be persisted back
- With no current user the guard follows `masked_attributes_nil_user_strategy` (`:bypass` default; `:hide` hides every guarded attribute but the primary key)
- Delegates per-attribute decisions to `AttributeAccessGuard`; `MaskedAttributes.explain(record, attr)` / `.explain_all(record)` for debugging
- Virtual readers (declared/discovered non-column fields) are wrapped only when `config.mask_virtual_attributes` selects the model (`Model.pf_mask_virtual_readers`, a separate prepended module); wrappers check the config at call time; a Masked value that is not a String/Symbol/Numeric is returned hidden; `record.pf_without_virtual_masking { }` is the escape hatch
- Store accessors (`masked_attributes/store_access.rb`): Rails reaches a store column through its (masked) getter, so while the column is hidden or masked a key reads as the hidden value without touching the column, and a key write runs against the stored hash (a fiber-local, per-record raw window) so the other keys survive
- Aliases (`masked_attributes/alias_access.rb`): each `alias_attribute` gets a reader and a writer that do what the Rails version in use does for an alias, plus the guard, in a module prepended to the declaring class's generated-attribute-methods module (also on a parent without the concern, where the accessor is gated on the record having it). They never call `super` (Ruby does not see the method behind such a module being redefined). `read_attribute` judges an alias as the attribute at the end of its chain
- Subclasses: when the concern arrives, the column methods Rails already generated for loaded subclasses are removed under Rails' attribute-method lock, so an early-loaded subclass is shaped like a late-loaded one. Never include or prepend a concern module into a subclass — it lands in front of the host's own methods
- A getter raises `ActiveModel::MissingAttributeError` for a column that was not loaded (`select(:id)`), as plain Rails does; a store accessor on an unloaded store column is left to Rails
- Does NOT intercept `pluck`/raw SQL (including a SQL alias, `select("email AS contact")`) — use `FiltersResponseAttributes` for those paths

### HasPermissionSetUsers (include on permission models)
- Replaces duplicated `users_on_permission_set` across 5 models
- 3 strategies: `:self` (PermissionSet), `:direct` (Resource, PermissionSetRule), `:via_resource` (ResourceField, ResourceAction)
- `permission_set_user_lookup :strategy` — declarative class method

### ValidatesDependency (include on Resource + ResourceField)
- Declarative boolean dependency validation DSL
- `validates_dependency :edit_access, requires: :read_access`
- Enforced: edit requires read, delete requires read, modify_all requires view_all, mask requires read
- **Skipped for muting permission sets** — inverted semantics (true = revoke, not grant)

### CrudActions (API controllers concern)
- Template Method pattern for standardized CRUD (index/show/create/update/destroy)
- Used by 4 API controllers: ResourceFieldsController, ResourceActionsController, PermissionSetRulesController, ResourcesController
- Template methods: `collection_scope`, `current_record`, `serializer_type`, `record_params`

---

## Services

- **`PermissionHashBuilder.call(user:, permission_sets:)`** — orchestrates permission hash building. Preloads every row in a fixed number of queries (7; 8 with a grantor), sorts each set's rows by id (`PermissionHashBuilder.sort_rows`), partitions sets into granting/muting, applies granting merge first, then muting subtraction. Delegates field logic to `FieldPermissionMerger`
- **`FieldPermissionMerger.call(fields:, resource:, configuration:)`** — merges one resource row's field rows (read/edit, mask AND logic, variant mappings). `merge_row(entry, field)` is the one definition of merging a row into an entry (also used by `Admin::EffectiveFields`): only rows that grant read decide the mask and its strategy. Accepts injectable `configuration:` for DIP
- **`ExtraFieldDefaults.call(entry:, resource_name:, configuration:)`** — gives declared extra (virtual) fields their implicit entry (`implicit_entry(permissions)`: read iff the merged resource grants read, edit iff it grants edit, never masked), only for names nothing configured and only under `extra_fields_default_access = :grant`. Called by `PermissionHashBuilder` once per resource after every granting set (never per set — that made the result depend on set order). Names are normalized to Strings
- **`PermissionRuleApplier.call(model_class:, rules:, args:, current_user:, operator_registry:)`** — row-level rule query building. Happy path is a single existence check (per-rule queries only on denial); identifiers quoted via `quote_table_name`/`quote_column_name`; a built-in operator's value is typed for its column by `Operators::ValueTyping` (a value the column cannot hold, or a field name that is not one → `none`), a custom operator gets it untouched; `join_type` is looked up in `JOIN_METHODS` (anything else raises `ConfigurationError`). Accepts injectable `current_user:` and `operator_registry:` for DIP
- **`PermitsAttributes.call(resource:, permitted_params:)`** — write-path: filters incoming params by field-level edit access. Non-mutating (returns a new plain Hash). A key the user cannot edit is dropped whatever its value; only `<assoc>_attributes` of an `accepts_nested_attributes_for` association recurses, record by record, against the child model's own Resource chain; a child absent from the user's hash drops the payload unless `nested_attributes_parent_fallback`; a nested `id` survives only inside the child's `permission_scoped` (`NestedRecords`, one query per payload); nested `_destroy` is kept only under the child's `delete_access` (`ResourceChain.grants?`)
- **`FiltersResponseAttributes.call(attributes:, resource_name:, user:)`** — read-path: removes fields without read_access, masks fields with mask_access. Fails closed: unconfigured fields go through `unconfigured_field_strategy` (default `:block`, registry pattern — extensible); nil-user behavior via `response_filter_nil_user_strategy` (default `:bypass`). Returns new hash (non-mutating)
- **`AttributeAccessGuard.call(resource_name:, attribute:, raw_value:, user:)`** — `resource_name:` is a name or a `ResourceChain`; per-attribute access decision (passed/masked/hidden/unconfigured/bypassed) shared by `MaskedAttributes` reads and response filtering. Returns `[include?, value]` tuple
- **`ResourceFieldGenerator.call(resource:, grant_all:)`** — auto-generates `ResourceField` records from model columns, plus declared virtual fields when `extra_fields_default_access = :unconfigured` (applies GDPR masks when `config.gdpr_defaults = true`)
- **`MaskValue.call(value, strategy:)`** — applies masking strategy to a value. Built-in: `full`, `email`, `last4`, `first1_last4`. Custom strategies via `config.custom_mask_strategies`. `MaskValue.strategies` returns merged built-in + custom hash.
- **`GdprFieldAuditor.call`** — scans existing ResourceFields for GDPR-sensitive fields that aren't masked AND unmapped model columns matching GDPR patterns. Returns report array, never auto-fixes
- **`ConsentWithdrawalHandler.call(user:, consent_flag:, dry_run:)`** — removes user from all permission sets gated on a consent flag
- **`DataSubjectErasure.call(user:, on_erasure:, dry_run:)`** — supports GDPR Art. 17: destroys assignments and memberships, clears cached permissions, scrubs name labels in the audit log (the current tenant's events when a tenant is set), optional host-app callback (after the commit when called inside a transaction). Ids and event data stay
- **`StaleAssignmentAuditor.call(threshold_days: 90)`** — reports permanent assignments unreviewed past the threshold (GDPR Art. 5(1)(e))
- **`PermissionForge.gdpr_filter_parameters`** — returns array of GDPR pattern regexes for use with `Rails.application.config.filter_parameters`. Auto-injected at boot when `config.filter_parameters_integration = true`. Manual: `Rails.application.config.filter_parameters += PermissionForge.gdpr_filter_parameters`
- **`BulkPermissionSetAssignment.call(permission_set:, user_ids:, action:, expires_at:)`** — bulk assign/revoke users. Accepts optional `expires_at:` for time-bound assignments. Each changed user is invalidated once, after the commit, by its assignment row; `invalidated` is `nil` inside a caller's transaction. Action strategy pattern via `ACTION_STRATEGIES` hash
- **`ExpiredAssignmentCleaner.call(dry_run:)`** — removes expired PermissionSetUser records and invalidates the cached permissions of affected users (rebuilt read-through on next access). `dry_run: true` returns counts without removing
- **`PermissionSetConditionEvaluator.call(permission_set:, context:)`** — evaluates activation conditions (session flag, IP range, login hours) against a request context hash
- **`PermissionSetCloner.call(permission_set:, attrs:)`** — deep-clones a permission set with all resources, fields, actions, and rules
- **`PermissionSetGroupCloner.call(permission_set_group:, attrs:)`** — deep-clones a group with all its permission sets
- **`ResourceWithFieldsBuilder.call(permission_set:, resource_name:)`** — creates a resource with full CRUD access + auto-generated fields
- **`DashboardStats.call`** — aggregates dashboard statistics from permission models
- **`SecurityAudit.call(configuration:, checks:, environment:)`** — read-only security review behind `rake permission_forge:audit` (`FORMAT=json`, `FAIL_ON=high`). One class per check in `services/security_audit/` (`config`, `privilege`, `assignment`, `rule` — also rules that match nothing, `unusable_rule_values` — `integrity`, `personal_data`, `action`, `audit_trail`), listed in `SecurityAudit.checks`; returns a `Report` of `Finding`s (critical → info)

---

## Operators

### Registry (Strategy Pattern)
- `lib/permission_forge/operators/registry.rb`
- Frozen Hash mapping 15 operator constants to callable objects
- `Registry.fetch(name)` returns a `#call`-able strategy
- Each strategy receives `(query, sanitized_column, rule, formatted_value)` and returns an `ActiveRecord::Relation`; for a built-in operator the value is already typed (Integer/BigDecimal, true/false, Date/Time, String; an Array for `in`, `not_in`, `between`)
- Adding a new operator = 1 hash entry + 1 method. Zero changes to `PermissionScopedFindable`.

### ValueTyping
- `ValueTyping.call(operator, value, rule_column)` types a rule's value by the operator's shape (`SHAPES`: single, list, pair, LIKE pattern) and returns `UNUSABLE` when the column cannot hold it or the field name is not a name — the applier then returns `none`, the RLS generator compiles `FALSE`
- `ValueCasters::BY_TYPE` has one caster per column type (adding a type = one entry); `ValueCasters::POSTGRESQL` holds the only database-specific ones (date/time text that is not ISO 8601 left as written, `real` in single precision); column types without a caster (arrays, uuid, json) are left to the database
- `RuleColumn.find(field_name, models)` resolves a field name the way the database does (schema columns, so `ignored_columns` count; any case on MySQL and SQLite; a schema or database prefix; the classes along the association path); `RuleColumn.models_along` is the one walk of an association path (applier and audit)
- `current_user` is substituted only where one value is compared (`ValueTyping.current_user?`), never inside a list or range
- `PermissionSetRule.filter_join_type?` is the one definition of "a filter on the model's own table" (nothing, blank, `filter`) — the applier, the default scope and the RLS generator all ask it

### Validations
- `lib/permission_forge/operators/validations.rb`
- Extensible operator-specific field value validation registry
- `Validations.validate(operator, field_value)` — returns `nil` or `{ field:, message: }` error hash
- Built-in validators for `between` (exactly 2 values), `in`/`not_in` (at least 1 value)
- Adding validation for a new operator = 1 `VALIDATORS` hash entry

---

## Admin JSON API

### Configuration

```ruby
config.api_enabled = true                    # false by default (opt-in)
config.api_auth = ->(controller) { ... }     # nil = 401 all, lambda = custom auth
config.api_base_controller_class = '::ActionController::Base'  # inherit from your own
config.api_pagination_handler = nil          # lambda(scope, page, per_page) for pagination
config.api_record_identifier = :uuid         # or :id
config.api_serializer_overrides = {}         # { permission_set: MySerializer }
config.api_require_authorization = true      # default: 403 on mutations until both authorization lambdas are set
```

### Routes (always drawn, guarded at runtime by `api_enabled`)

All under engine mount path + `/api/`:
- `GET/POST /api/permission_sets` + `GET/PATCH/DELETE /:identifier` + `POST /:identifier/clone`
- `GET/POST /api/permission_sets/:ps/resources` + nested `/fields`, `/actions`, `/rules`
- `GET/POST/DELETE /api/permission_sets/:ps/users`
- `GET/POST /api/permission_set_groups` + `GET/PATCH/DELETE /:identifier` + `POST /:identifier/clone` + nested `/users`
- `GET /api/stats`
- `GET /api/audit_events` + `GET /api/audit_events/:identifier` (read-only)

### Response envelope
- Single: `{ data: { ... } }`
- Collection: `{ data: [...], meta: { pagination: { page, per_page, total_count } } }`
- Error: `{ error: { status: 422, messages: { field: ["..."] } } }`

### Auth tiers
1. `api_auth = nil` → 401 (safe default)
2. `api_auth = lambda` → flexible (roles, tokens, API keys)
3. `api_base_controller_class` → inherit host app's auth chain

### Hardening
- CSRF: `protect_from_forgery with: :null_session` on the API base controller
- `is_editable: false` records return 403 on mutation
- Every lookup by `:identifier` goes through `BaseController#find_record` — never `find_by!(api_record_identifier => params[...])` directly: under `api_record_identifier = :id` only digits name a record (the database casts `'1abc'`, or a uuid starting with digits, to an id), and a NUL byte names nothing
- `api_action_authorization` / `api_assignment_authorization` lambdas gate all mutation + assignment endpoints

### AMS support
`ams_serializer?` auto-detects AMS subclasses and switches render strategy (`render json: record, serializer:` vs `as_json`).

---

## Cache Format (public contract — do not change structure)

```ruby
{
  profile: { id:, uuid:, name:, email: },
  preferences: {},
  permissions: {
    resources: {
      Customer: {
        permissions: { read_access: true, create_access: false, edit_access: true, delete_access: false },
        fields: {
          name:  { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
          email: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }
        },
        actions: {
          sync:   { is_permitted: true },
          export: { is_permitted: false }
        },
        source_permission_sets: [{ uuid: "set_uuid_1", name: "Set Name", is_muting: false, ... }],
        permission_set_rules: [{ name: "rule1", operator: "equal", field_name: "status", field_value: "active", ... }]
      }
    }
  }
}
```

---

## Multi-Set Merge Logic

When a user belongs to multiple permission sets, sets are partitioned into **granting** (`is_muting: false`) and **muting** (`is_muting: true`).

### Phase 1 — Granting (additive, most-permissive-wins)

- **Resource CRUD / Field read/edit**: `||=` — TRUE wins (if any granting set allows, user has access)
- **mask_access**: AND logic over the rows that grant read — FALSE wins (if any granting set unmasks, user sees full value); a Hidden row (read off) never votes
- **mask_strategy**: first strategy of a read-granting row wins (sets merge in `created_at, id` order, rows within a set in id order)
- **Resource action is_permitted**: `||=` — TRUE wins (if any granting set permits, user can perform action)
- **Permission set rules**: Accumulative (all rules from all granting sets apply together, so they intersect: a set with a rule narrows rows another set allowed)
- **Extra (virtual) fields**: after all granting sets are merged, a declared name with no entry gets the resource's read and edit, unmasked (`ExtraFieldDefaults`) — a row in any of the user's sets wins. Skipped under `extra_fields_default_access = :unconfigured`

### Phase 2 — Muting (subtractive, deny overrides allow)

- **Resource CRUD / view_all / modify_all**: Set to `false` if muting resource has it as `true`
- **Resource read muted**: every field entry of that resource (variants and implicit virtual fields included) is forced to `read_access: false, edit_access: false`; a muted edit mutes only the flag
- **STI**: a muting resource reaches every entry whose `ResourceChain` names it (a muted base reaches the subclass entries; a muted subclass only itself)
- **Field read/edit access**: `read_access` set to `false` if the muting field has it as `true`; `edit_access` set to `false` if the muting field has read or edit as `true`
- **Field mask_access**: Forced to `true` if muting field has `mask_access: true`
- **Field variants**: Muting a field also mutes its configured variants (`_id` → `_uuid`, `_cents` → base name) via `Configuration#field_variants_for`
- **Action is_permitted**: Set to `false` if muting action has `is_permitted: true`
- **Rules**: Muting sets do NOT add rules (subtraction only)

Granting sets cannot revoke each other, but muting sets can revoke anything.

---

## SOLID Principles (mandatory on all new code)

All new code must respect SOLID principles. Apply this checklist before finalizing any change:

- **SRP** — Each class/module has one reason to change. Services do one job. Concerns are focused. If a class does two unrelated things, split it.
- **OCP** — Prefer strategy/registry patterns over case/if-else chains. Adding a new variant (operator, mask strategy, action type) should require adding code, not modifying existing code.
- **LSP** — Subclasses and concern-including classes must honor the contracts they inherit. All operator strategies must accept `(query, col, rule, val)` and return a Relation. All `users_on_permission_set` implementations must return a collection.
- **ISP** — Concerns should be small and focused. Don't force including classes to implement methods they don't need. Prefer composition (`PermissionedUser` = 3 sub-concerns) over one large mixin.
- **DIP** — Depend on abstractions (lambdas in Configuration, injectable parameters) not concretions. New services should accept dependencies as keyword arguments with sensible defaults (e.g., `current_user: PermissionForge.current_user`).

### DRY checklist
- Before creating a new pattern, check if a shared concern or partial already exists (`HasActiveScope`, `Clonable`, `NestedResourceLookup`, shared view partials)
- If you write the same block 3+ times, extract it
- Cloning logic uses `Clonable#duplicate_record`
- Admin batched edits go through `Admin::ChangeSet` (review → apply); locked (`is_editable: false`) records are refused in the controller AND skipped in `ChangeSet`
- API nested resources use `NestedResourceLookup#set_resource/find_nested_record`
- Admin UI pieces use the shared partials in `app/views/permission_forge/shared/` and `pf_*` helpers

---

## Admin UI rules

- Zero host dependencies: assets are served by `AssetsController` from `app/frontend/` — never add files to `app/assets` or rely on Sprockets/Propshaft/importmap
- Namespace everything: `pf-*` classes, `data-pf-*` attributes, `pf_*` cookies (scoped to the mount path), `pf_*` helpers. `test/permission_forge/html/admin_pages_test.rb` and `assets_test.rb` enforce this
- Strict CSP: no inline `style=`, `<script>` without `src`, or `on*=` handlers
- Every flow must work without JS: drawers/dialogs are real GET pages; `pf_admin.js` only enhances (`X-PF-Fragment` header → fragment layout)
- Every state needs a glyph + a word (never colour alone); keep UI names verbatim: Permission Set, Muting Permission Set, Permission Set Group, Resource
- Markup is built with `tag`/`content_tag`/`safe_join`/`tag.attributes` (`pf_attrs_when`); never `html_safe`, `raw`, `safe_concat`, `<%==` (guarded by `html/no_hand_marked_safe_test.rb`, empty allow-list). A drawer/confirmation title is the page `h1` when standalone (`h2` in the dialog); section headings go through `pf_section_heading`; `html/admin_accessibility_test.rb` lints every page and fragment. A page's logic lives in an `Admin::*` read model (`FieldDetail`, `AuditEventDetail`, `RuleBuilder`), the template draws it. `pf_admin.js`: `const`/`let` only, fragments via `setContent` (DOMParser, no `innerHTML`; `html/admin_script_hygiene_test.rb`)

## Rules

- Never change the cached permission hash structure — host apps depend on it
- **One emitter for audit events**: `Audit.record` / `Audit.instrument`. Nothing else builds or stores an `AuditEvent` (`Recorder` + `AuditEvent.store!`), with one exception: `Audit::SettingsObserver` stores `audit.settings_observed` through `Recorder#store!` directly while `audit_events == false`, so an "off" period stays visible; the only `update_all` / `delete_all` on audit rows are the erasure label scrub and the retention purge, each recorded by its own event, and the purge keeps `audit.purged`. No route, form or API parameter writes or deletes an event
- **Every write to the 8 permission models runs callbacks.** No `update_all`, `delete_all`, `update_column(s)`, `insert_all`, `upsert_all`, `touch` or raw SQL on them in `app/`, `lib/` or rake tasks — each would be an unaudited change. The guard test `test/permission_forge/audit_integration/callback_bypass_guard_test.rb` (T11) enforces it. Never ask Rails' transaction callbacks directly; a refusal that must survive a rollback goes through `Audit::Detached`
- **A new event = one `EventCatalog.register` entry + one sentence key per locale** (`permission_forge.audit_log.sentences.<event>` in en, sq and mk). A test fails for a catalogued event without a sentence in every locale. An access event also needs a runtime group; a new audited admin page is one `AuditedViews.register` call
- **Actor and source never come from parameters or headers; the request id and IP are client-influenced (`request.remote_ip`, `X-Request-Id`: say so in docs); `reason` is the one parameter read, capped at 255.** All of them reach events through `Audit::Context`
- **Compliance wording** (docs, skills, UI, CHANGELOG): say "supports evidence for", and give each control as "what the gem evidences (name the event or feature) / what the host must add". Never claim compliance, certification or "audit trail" for something that is not an `audit_events` row (`audit_trail_enabled` is created-by/updated-by; `PermissionsRegenerator` is cache invalidation). ISO 27001 means the 2022 Annex A numbering. Every sentence about audit, logging or a standard must have code behind it
- All 8 models (and `AuditEvent`) define `table_name` as a method — the one-line `def self.table_name = "#{PermissionForge.table_name_prefix}…"` used throughout (a real method, evaluated on every call) or a multi-line `def … end` — never the assignment `self.table_name = "…"`, which freezes the prefix when the class loads
- **A column that stores a host key has the host key's type** (`user_id`, `created_by_id` / `updated_by_id`, `reviewed_by_id`, `sensitive_acknowledged_by_id`, every tenant column): the install generator types them from the host models, the upgrade copies the types already there, and `Services::HostKeyGuard` raises at the point of use when an integer column would truncate a UUID or string key. A new such column must follow the same types and, if an authorization decision or tenant isolation depends on it, be added to `HostKeyGuard`
- Keep zero hard dependencies — all host-app integration via lambdas in Configuration
- `PermissionScopedFindable` must remain safe when `current_user` is nil (silent bypass)
- `NotAuthorizedError` must stay at `PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError`
- Tests use the `test/dummy/` Rails app with SQLite — keep it minimal
- Field variant mappings (`_id` → `_uuid`, `_cents` → base name) are configurable — don't hardcode
- "In effect / managed" has one definition: `Resource.in_effect` / `ResourceAction.in_effect` (and `#in_effect?`) — never re-derive it
- Declared virtual-field names have one reader: `PermissionForge::VirtualFields` — never call `extra_fields_method` directly
- The guard path must never turn an error into "unmapped" (which is allowed): raise instead
- The Resource entries a model class answers to are resolved in one place, `ResourceChain` (own name + STI ancestors on the same table; rules of all apply, a bypass skips only its own entry's rules, the strictest field entry wins) — never look a resource up by `klass.name.to_sym`
- Row order has one definition, `PermissionHashBuilder.sort_rows` (the builder and `Admin::EffectiveAccess` both call it)
- Every private method a concern adds to a host model (the User concerns, `MaskedAttributes`) is `pf_`-prefixed; the public User API is exactly the documented list. Guard tests: `release_readiness/host_user_namespace_regression_test.rb` (User) and the CQ-N1 test in `release_readiness/authorization_semantics_regression_test.rb` (MaskedAttributes). `active_non_expired_permission_sets` is the one allow-listed alias (until 1.0)
- A new strategy option goes into `Configuration::StrategyValues::ALLOWED`, never a bare `attr_accessor` compared with `==` at the point of use
- A user's cache keys have one definition, `Cache::UserKeys` — a key added to `invalidate_permissions` goes there, or the bulk path (`HolderInvalidation`) misses it
- **A new reliance on a private Rails API needs a canary test.** Anything `:nodoc:`, private (`send`, `instance_variable_get`), undocumented, or a prepend onto a Rails class goes in `test/permission_forge/rails_internals_canary_test.rb` as a `canary_test :key` with a `TOUCH_POINTS` needle (the code that relies on it) and a `FIXES` entry (what to change). Assert only what the gem relies on (an added optional argument or a better Rails answer must not fail it). Remove the canary with the reliance (its meta test fails when the code is gone)
- `PermissionForge::RLS` takes a connection with `connection_pool.with_connection` for one unit of work and `lease_connection` (7.1: `connection`) only for the session-scoped `set_user!` / `clear_user!` — never `ActiveRecord::Base.connection`
- **Per-execution state goes through `PermissionForge::ExecutionState` only** — never `Thread.current`, `Fiber[]`, `ActiveSupport::IsolatedExecutionState`, a `CurrentAttributes` class or `thread_mattr_*` outside it, unless the guard's `ALLOWED` list names the file and why (`test/permission_forge/execution_state_test.rb`). A new slot = one `KEYS` entry: `pf_` name, scope (`:fiber` when its value seen by other code would widen access or drop audit events; `:execution` for request-wide state like the audit context), `:clean` unless it is a counter or emptying it inside its block would fail open (`:pf_cache_failure_collectors`, `:pf_store_errors`), and what it holds. Set a block-scoped value with `ExecutionState.with`. The end of an executor run only removes what the run added — never write a value back: `ActionDispatch::Executor` completes a run after the middlewares above it returned. A `run!(reset: true)` completing an outer run inside a block empties that block's slot (fails closed)
- The nine models are autoloaded: no `require` of a model in `lib/`, no model constant evaluated at require time (`controller_actions.rb` reads `PermissionForge::RESOURCE_NAME_FORMAT`, not `Resource::NAME_FORMAT`), no model reference in an engine initializer; a Duration or other core-extension value evaluated as a `lib/` file loads needs its own `require 'active_support/core_ext/...'`. `apply_tenant_scoping!` is called by each model's class body (after its macros); `PermissionForge::TestModels.apply_tenant_scoping!` (`test/support/test_models.rb`) does it for the test suite, which turns tenancy on after boot
- Every `belongs_to` in `app/models/permission_forge/` states `optional:` (the host's `belongs_to_required_by_default` applies to the models now); a new one does too. Tenant: `HasTenantScoping#tenant_scoping_options` (`{ optional: false }`, `AuditEvent` `{ optional: true }`)
- `DEFAULT_GDPR_FIELD_PATTERNS` serves masking detection and `filter_parameters` alike; each alternative stands alone (no inner `|` group) so `Admin::SensitiveColumns` can name it; short stems match a name segment (see `gdpr_default_patterns_test.rb`)
- **Renamed or removed public API goes through `PermissionForge.deprecator`** for at least one minor version and gets a CHANGELOG **Deprecated** entry. The old name calls the new one — never `alias_method` on `Configuration` (it skips the prepended writers: `StrategyValues`, `Presets`). `Deprecation::HORIZON` is the removal version; a test fails when `VERSION` reaches it
- **Library defaults never change silently.** A new fail-open option gets a README checklist row and a `Presets::STRICT`/`COMPAT` entry (or `OPT_IN`) in the same change — `configuration_presets_test.rb` parses the README checklist. A new preset option's writer must store `@<option>` (the preset writes the ivar)
- Whether a record hides its guarded attributes with nobody signed in has one definition: `Configuration#hide_masked_attributes_without_user_for?(klass)` — `:hide`, except the user model (`user_model_class?`). Never ask `hide_masked_attributes_without_user?` for a record
- `without_permission_scope` is the host's opt-out: with nobody signed in, `find_by` / `find_by!` / `permission_scoped` apply no rules inside it. The gem never calls it for itself (only the admin controllers, after the host's authentication): use `AutoPermissionScoping.internally_suspended { }` (a test enforces it); `host_suspended?` tells them apart. Both flags stay in one (fiber-local) storage scope
- Validators read the stored value of the attribute they validate (`ValidationReads`), only while they run; error `value:` options are replaced with what the current user reads
- **Every class and module under `PermissionForge::` says `@api public` or `@api private`** in the comment above it (`test/permission_forge/api_boundary_test.rb`; a private namespace covers its children, a public one does not). Public methods carry a docstring (`bundle exec rake yard:check`, floor `YARD_UNDOCUMENTED_FLOOR` in the Rakefile; lower it, never raise it). Public = README "Versioning and stability"
- The `ControllerActions.guarded?` guess is gone: when `_process_action_callbacks` cannot be read it raises `ConfigurationError` (the catalog drops the entry, `SecurityAudit` reports `action_guard_missing`) — never answer "guarded" without looking
- Conditional sets are selected per read in one place, `PermissionsPerContext` with `ConditionalSets` — never evaluate activation conditions when the hash is built, and never store a hash that includes a conditional set under the base key
- "Remove every cached permission" goes through `PermissionCacheClearer` (a pattern removal only counts when the canaries are gone; else enumerate) — never call `delete_matched` with an unanchored String pattern (memory and file stores read it as a Regexp)
- A person is looked up by id only through `Admin::PeopleDirectory#find` / `#find_all` (within `user_list_resolver`; outside → not found), in the admin and the API
- `Admin::EditableLock` decides locks (`widens_access?`, `widening_lock`): narrowing access is always allowed, widening refused, in the set's direction (granting: removing holders / shortening an end date narrows; muting: adding holders / extending narrows); anything that changes what a locked record holds is refused
- `Resource` rows announce newly named models through `MaskingSync` — never call `MaskedModels.apply` from a new path without considering the other processes
- Request params are shaped through `ParamShapes` (`pf_require_hash`, `pf_hash_param`, `pf_text_param`, ...); crafted input is a 4xx, never a 500
- A rule value is typed in one place, `Operators::ValueTyping` — the applier and `RlsOperatorSql` both call it. A value the column cannot hold must deny, never fall through to the database. Never branch on the adapter outside `ValueCasters::BY_ADAPTER` and `RuleColumn::EXACT_NAMES`
- Rule data never reaches `send`: `join_type`, operators and casters are registry lookups
- An RLS policy must select what `PermissionRuleApplier` selects and never more (`test/rls/rls_rule_parity_test.rb`); changing what a rule compiles to needs a `RlsPolicyGenerator::GENERATOR_VERSION` bump (apps then re-sync)
- "A transaction is open" and "a transaction withholds" have one definition each: `OpenTransaction.current` / `.withholding` — never re-derive them, and never register an invalidation through `ActiveRecord::Transaction#after_commit` (Rails skips it when any commit callback raises): use `OpenTransaction#after_commit`
- Ask `Cache::Failure.none? { … }` whether an invalidation went through — never the return value of `invalidate_permissions`, which hosts override
- A normal invalidation never reads and never removes per-context variants; whatever must remove personal data from the cache now (erasure, clear) calls `Cache::VariantRemoval` after the users' invalidation — erasure without reading the index entries (a failed read is silent on ActiveSupport stores)
- An empty permission hash is never a safe fallback: it denies every `can_*?` check but also empties `permission_set_rules`, which switches row-level rules off
- Objects kept on a user or record instance must survive `Marshal.dump` (`InvalidationBatch` and `OpenTransaction` dump as nothing)
- All user-facing strings must use I18n `t()` — never hardcode English in views/controllers/helpers
- Locale files follow `permission_forge.<locale>.yml` naming — all keys under `permission_forge:` namespace
- When adding new UI strings: add key to all 3 locale files (en, sq, mk)
- **I18n checklist (mandatory on every change that touches views, helpers, controllers, flash messages, or validation messages):**
  1. Search for any new hardcoded English strings — replace with `t()` calls
  2. Add the new key to **all 3 locale files** — never just English
  3. Keep keys alphabetically sorted within their YAML section
  4. Use `default:` fallback for dynamic keys (e.g., `t("...#{key}", default: key.humanize)`)
  5. Run `bundle exec i18n-tasks health` to verify — zero missing, zero unused
  6. If a feature adds new model validations, ensure error messages are i18n-backed
- Run `bundle exec i18n-tasks health` to verify translation completeness

---

## Testing

- Minitest + custom test helpers, ~4,460 tests, 97%+ line coverage
- Creating a `PermissionForge::Resource` row named after a real model mixes `MaskedAttributes` into that class for the rest of the test process — use `Customer`/`Supplier` or the dedicated `PfVirtual*` models, never `Account` or `User`
- Alias and subclass fixtures for `MaskedAttributes` live in `test/permission_forge/masked_alias_models.rb`. The `PfPlain*` models are the plain-Rails twins the others are compared with: they must never get a `Resource` row
- **Auditing is on for the whole suite** (`:auto`, the dummy schema has the table; the audit config is restored with the rest of the configuration; setup resets the table check and context). Never assert an absolute `AuditEvent.count` — use `assert_difference`, scoped queries, `assert_audit_event(name, **attrs)` and `audit_events_for(record_or_name)`. `AuditEvent` is tenant-scoped: baseline with `AuditEvent.unscoped`. A test that sets `current_user_resolver` or any audit option must restore it
- The PostgreSQL test database is shared between worktrees: never run two `DB=postgres` suites at once (a concurrent run drops tables under the other: `PG::UndefinedTable`)
- The suite runs on a non-default configuration (empty prefix, hand-written `test/dummy/db/schema.rb`, tenancy on), so the shipped defaults are covered by child-process tests that generate a real app: `test/permission_forge/install/fresh_install_test.rb` (support: `test/support/fresh_install_app.rb`) and `test/permission_forge/audit_integration/install_upgrade_e2e_test.rb` (fresh install with the default and an empty prefix, upgrade from a 0.12.2 schema). Run them when changing a generator, a migration template, defaults or the cache path. `render_install_template` (`test/support/install_templates.rb`) renders a template the way the generator does
- Test helpers in `test/test_helper.rb` — `create_user`, `create_permission_set`, `create_resource`, `create_resource_field`, `create_resource_action`, `create_permission_set_user`, `create_permission_set_rule`
- Dummy app: `test/dummy/` with User, Customer, Current models
- `test_helper.rb` configures the suite's base (memory cache, no table prefix, audit trail off, tenancy on, the suite-only API/field options) once, in its `configure` block; `ConfigurationSnapshot` (`test/support/configuration_snapshot.rb`) puts exactly that back before and after every test, also after `PermissionForge.reset!` or an in-place change, so a teardown that raises leaks nothing into the next test. A new suite-wide setting goes in the `configure` block, never in a per-test reset. Non-configuration state (cache, owed invalidations, audit context, tenant, locale, `Current`, `Rails.logger`) is reset by name in test_helper
- The SQLite suite runs in forked workers (`test/support/parallel_workers.rb`, Rails `parallelize`, 8 by default; `PARALLEL_WORKERS=1` for serial). Each worker starts from a copy of the parent's in-memory database. PostgreSQL, MySQL and Rails < 8.1 run serial. A test that uses something every worker shares (the local Redis db 15, a fixed path) includes `ParallelWorkers::SharedResource` or uses a per-process path
- Swap a method with `replace_singleton_method` / `replace_method` (`test/support/method_stubs.rb`), never by defining over it (a `method redefined` warning under `-w`). No wall-clock `sleep`: `travel_to` for expiry, wait for a condition for threads
- The dummy app logs at `:warn`; a test that asserts a log line installs its own logger (teardown restores the suite's)
- `test/permission_forge/rails_internals_canary_test.rb` — the Rails-internals canary (~48 tests, ~0.5 s); run it first after a Rails upgrade, and on each `gemfiles/rails_*.gemfile`. CI runs it on Rails main in the allow-failure `rails-main` job (`gemfiles/rails_main.gemfile`, no lockfile)
- The models are autoloaded: a test that needs a model loaded with another configuration declares the association itself (`DeclaresAuditUserClass#declare_audit_user_class`), under `silence_warnings`; `Rails.application.reloader.reload!` behaviour is covered by the child-process `install/model_loading_test.rb`. `PermissionForge::TestModels.all` (`test/support/test_models.rb`) is every model class
- `install_template_configuration` evaluates the generated initializer on a fresh Configuration — assert what it configures. Never include a gem concern into a dummy model (or create a Resource row named after one) in a test: it stays for the rest of the process
- The suite also runs, green, on MySQL (CI job, `DB=mysql BUNDLE_GEMFILE=gemfiles/mysql.gemfile`, `MYSQL_HOST/PORT/USER/PASSWORD`) and PostgreSQL (`DB=postgres`; `rake test:rls` for the policy tests); database-specific tests skip by adapter with a reason. `PfRuleRecord` (`test/permission_forge/rule_value_models.rb`) has a column of every typed kind
- SQLite is a snapshot database under `config.snapshot_transactions = :auto`, PostgreSQL is not: tests of the withheld path set the option to `true`, tests of the pass-through path to `false`. The fixture transaction does not count as open; use `use_transactional_tests = false` (and clean up) only where the real transaction stack matters
- `test/permission_forge/cache/failing_store.rb` is a cache store that fails without raising. Never name a test ivar `@failures` (Minitest uses it)

---

## Gem Publishing

- Public on GitHub: `https://github.com/fetijashari/permission_forge`; published on RubyGems as `permission_forge` since 0.14.1
- Releases follow `RELEASING.md`: a "Release vX.Y.Z" pull request (bumps `version.rb`, dates the CHANGELOG heading) is squash-merged, then an annotated `vX.Y.Z` tag on the squash commit runs `.github/workflows/release.yml`, which publishes by RubyGems Trusted Publishing (OIDC, no API key) after a reviewer approves the `rubygems` environment. Never `rake release` (it tags and pushes the branch)
- A release produces: the gem on RubyGems.org with its Sigstore attestation (`gem push --attestation`), a GitHub build provenance attestation (`provenance` job, `actions/attest`), and a GitHub Release for the tag (`github-release` job, `gh release create --verify-tag`, notes = the version's CHANGELOG section, taken by `.github/scripts/release_notes.sh` in the `build` job before the approval; CI `lint` runs the same script for `VERSION`) with `permission_forge-X.Y.Z.gem`, `.gem.sigstore.json` and `.gem.intoto.jsonl` attached — names Scorecard's Signed-Releases check counts. Only `github-release` has `contents: write`; only `publish` and `provenance` mint OIDC tokens. Verification commands: RELEASING.md "Verifying a release"
- `v*` tags are immutable (rulesets: no deletion/update/force-push, creation by repository admins only); `main` takes pull requests only, squash or rebase (linear history), with the CI checks required
- The gem is built and checked by `.github/scripts/build_gem.sh` (umask 022, `gem build --strict`, `verify_gem.rb`: modes, version, file list = gemspec); CI's `lint` job runs it on every pull request
- Version in `lib/permission_forge/version.rb`
- Changelog in `CHANGELOG.md`
