# Migration Guide

## Upgrading to 0.15

**What an existing 0.14 install must run:** nothing for the database — 0.15 adds no table and no column, and `bin/rails generate permission_forge:upgrade` adds no migration a 0.14 install does not have. Run the audit before you deploy, re-sync RLS policies after (PostgreSQL only), and read the behaviour changes below. An app still on 0.13 upgrades to 0.14 first ([below](#upgrading-from-013-to-014)).

### Before the deploy: run the audit

Run the 0.15 security audit against your data before production runs 0.15 — from a branch with the new gem against a copy of the data, or on a staging deploy: the 0.14 audit does not know most of these findings. It changes no permission data (it records one `report.generated` event):

```bash fragment
bin/rails permission_forge:audit
```

It lists the rows 0.15 reads differently. Fix them before production sees the new behaviour:

| Finding | What 0.15 does with such a row |
|---------|--------------------------------|
| `missing_rule_columns` | A rule naming a column, table or association path that is not there matches nothing (its holders are denied every record), and is refused when created or changed. |
| `unknown_rule_operators` | A rule with an operator or join type this version does not know matches nothing. |
| `unusable_rule_values` | A rule whose value its column cannot hold matches nothing, and a new or changed one is refused. On PostgreSQL this now includes `uuid` / `inet` / `cidr` / native enum values PostgreSQL could not read (they raised before), date or time text PostgreSQL cannot read, a LIKE operator on a non-text column, and every rule on a `json` / `jsonb` / array column under an operator other than `is_null` / `is_not_null`. |
| `secret_rule_columns` | A rule comparing a password digest, a token, an encrypted value or a secret keeps applying, but a new one, or a change of its column, is refused. |
| `incomplete_conditions` | An activation condition the validation refuses (a bad IP entry, one hour of the two, the same hour twice) is unjudgeable: a Muting Permission Set applies to every request, a granting set never passes. |
| `variant_rows_conflict` | An explicit field row for a variant name (`owner_uuid` next to `owner_id`) now decides that name, whichever row is older. |
| `dependency_violations` | A row that skips a required permission (edit without read, Modify All without View All), written past the validation, no longer grants the dependent permission. |
| `unknown_mask_strategies` | A field masked with a strategy this app does not know is masked fully. |

### Behaviour changes

Each with its opt-out, or why there is none. The [CHANGELOG](../CHANGELOG.md) has the full list.

1. **`include_nulls` defaults to `false`** for a rule made in code, through the API and in the admin's builder (before, the column default `true` let the NULL rows of a rule created in code or through the API through). Stored rules keep their value. **Opt out:** pass `include_nulls: true` (code, API) or tick "Also show records where … is empty" in the builder, per rule. See [The `include_nulls` Flag](row-level-rules.md#the-include_nulls-flag).
2. **Rules on a column that holds a secret are refused** when created or when their column, path, join type or resource changes. **Opt out:** `config.rule_secret_column_patterns = []`, or a narrower list.
3. **A rule value its column cannot hold is refused on save** (`field_value`: "is not a value Customer.owner_id can hold"; 422 in the API). **No opt-out:** such a rule could only deny every record; stored ones keep matching nothing and are listed by `unusable_rule_values`. See [A value the column cannot hold](row-level-rules.md#a-value-the-column-cannot-hold).
4. **PostgreSQL types rule values more closely:** date or time text in another notation than ISO 8601 and column types without a caster (`hstore`, `money`, `interval`, `macaddr`, `xml`, ...) are asked of PostgreSQL once per process — what it cannot read matches nothing and is refused on save (it raised for every holder); a LIKE operator matches text columns only; a uuid in braces, after `urn:uuid:` or without hyphens is read as the uuid it holds. **No opt-out:** such a rule never matched a row; a custom operator still gets the value as written. See [How Values Are Compared](row-level-rules.md#how-values-are-compared).
5. **A rule on a `json`, `jsonb` or array column matches nothing** under every built-in operator but `is_null` / `is_not_null`. **Opt out:** register a custom operator (`operator_registry:`), which receives the value as written.
6. **The field generator writes fewer rows.** `ResourceFieldGenerator.call(resource:)` (also the API's `generate_fields` without `grant_all`) creates the personal-data columns Hidden like the others, with their recommended mask strategy on the row (they were readable and masked), and on a Muting Permission Set writes no row at all. `grant_all: true` gives every field full access, unmasked. Rows already written are not changed. **Opt out:** add the personal-data columns Read-only in the admin (under `gdpr_defaults` they start Masked), or generate with `grant_all: true` and mask what `rake permission_forge:audit_masks` lists.
7. **Generated rows give `created_at` / `updated_at` a row** (at most read-only on a granting set); right after the upgrade the admin lists them as not configured on every existing Resource until you sync its fields. **Opt out:** `config.ignored_fields += %w[created_at updated_at]`.
8. **An explicit field row for a variant name decides that name**, and **a broken activation condition is unjudgeable** (see the table above). **No opt-out:** the explicit row is what the admin wrote; a lockdown that never locked was the defect.
9. **An unrescued denial answers 403** (`NotAuthorizedError`, `ActionNotAuthorizedError`), not 500; in production an HTML request gets an empty page until you add `public/403.html`. **Opt out:** rescue the errors yourself, or set another status in `config.action_dispatch.rescue_responses`. See [Handling Denials](row-level-rules.md#handling-denials).
10. **API answers.** A refusing `api_auth` is 401 (was 403); every 422 is `{"error": {"status": 422, "messages": {"<field>": ["…"]}}}`, keyed by the request parameter or `base`; an `expires_at` given as a date means the end of that day, and one that is not after now is a 422; unrouted paths, `OPTIONS`, `TRACE` and extensions other than `.json` answer the JSON 404 envelope; `null` for a NOT NULL attribute is a 422 keyed by it; `DELETE …/permission_sets/:uuid/users/:uuid` answers 200 with the removed assignment and `meta.cache` (was 204), `POST …/users` adds `meta.cache`. **No opt-out:** see the CHANGELOG for each answer and what a client reads instead.
11. **Permission Set names are unique within a tenant** (ignoring case and surrounding spaces) for a new set or a rename; two sets that already share a name stay valid until one is renamed. **No opt-out:** give duplicates distinct names.
12. **More boot warnings are `SECURITY warning:`** (a model loaded with another `tenant_model`, masking that could not be synced, a per-process cache or unannounced masking in production, row-level security on an adapter that is not PostgreSQL), and the production cache and masking warnings lost their `WARNING:` prefix. **No opt-out:** update a log alert that matched the old text; each warning names the setting that removes its condition.

### If you override the gem's locale keys

The gem's own locales are complete. Only a host whose locale files override one of these keys (all under `permission_forge.`) renames it:

| 0.14 key | 0.15 key |
|----------|----------|
| `ui.levels.*` | `ui.states.field_level.*` |
| `ui.states.granted`, `ui.states.blocked`, `ui.states.none` | `ui.states.effective.granted`, `.blocked`, `.none` |
| `people.effective_tab.hidden_by_muting` | `ui.states.effective.hidden_by_muting` |
| `audit_log.actor_types.*` | `ui.states.actor.*` |
| `ui.badges.locked` | `ui.states.lock.locked` |
| `shared.crud_cell.needs_read` | `ui.needs_read_first` |
| `settings.row.default`, `settings.row.docs` | `settings.row.default_html`, `settings.row.docs_html` |
| `permission_set_rules.builder.message_placeholder` | `permission_set_rules.builder.message_help` (a hint under the field, not a placeholder) |
| `home.index.search_placeholder` (the long sentence) | `home.index.search_placeholder` is now "Name or email"; the sentence moved to `home.index.search_help` |

Removed without a replacement: `ui.levels.muted`, `ui.badges.not_configured`, `ui.audit.system`, `people.effective_tab.legend_muted`, `people.effective_tab.legend_none`, `shared.across_sets.muted_hidden`. See [i18n.md](i18n.md#overriding-translations).

### Removed and deprecated

Removed in 0.15:

- `PermissionForge::Engine.apply_masked_attributes_to_managed_models` — call `PermissionForge::MaskedModels.apply(only:)`.
- The 0.13 cache keys (`user_<id>`, `tenant_<t>_user_<id>`) are no longer removed by an invalidation. An app still on 0.13 upgrades through 0.14, or deploys 0.15 and runs `bin/rails permission_forge:cache:clear` once its 0.13 processes are gone (a 0.13 process's invalidation cannot reach the 0.15 entries).

Deprecated in 0.15, removed in 0.16 (each warns through `PermissionForge.deprecator`):

- An `api_auth` that sets `@admin` on the controller to open `GET /api/stats` — set `config.api_stats_authorization`.
- The `pf_time_ago` helper — use `pf_relative`.
- `PermissionForge::Admin::SensitiveColumns` — use `PermissionForge::SensitiveColumns`.

### After the deploy: RLS (PostgreSQL)

`RlsPolicyGenerator::GENERATOR_VERSION` is 7, so `bin/rails permission_forge:rls:status` reports every table as `STALE — run permission_forge:rls:sync` (and exits 1) until you sync. The old policies stay in force until then — wider than the application layer for a set with only an end hour. Run once the new code is live:

```bash fragment
bin/rails permission_forge:rls:sync
```

See [what version 7 changes](query-scoping.md#level-3--database-postgres-row-level-security).

### The `include_nulls` column

A 0.15 install creates `include_nulls` with the default `false`; a 0.14 install keeps the column default `true`. Nothing needs to change: the model declares the default (`false`), so every rule created through the model — code, API, admin — gets `false`; only a row inserted with SQL, past the model, takes the column default. To align the column anyway, a migration of your own (use your table prefix):

```ruby fragment
class ChangePermissionForgeIncludeNullsDefault < ActiveRecord::Migration[7.1]
  def change
    change_column_default :permission_forge_permission_set_rules, :include_nulls, from: true, to: false
  end
end
```

## Upgrading from 0.13 to 0.14

No migration is needed: 0.14 adds no table or column. Several defaults are stricter; go through these steps before you deploy.

1. **`api_require_authorization` is now `true`.** With the API on, every change and assignment is refused (403, `api.auth_failed`) until both `config.api_action_authorization` and `config.api_assignment_authorization` are set. Set them, or opt out with `config.api_require_authorization = false` (not recommended: the boot warning and `rake permission_forge:audit` flag it). See [admin-api.md](admin-api.md#security-considerations).
2. **With `tenant_model` set, the admin and the API need a current tenant.** A request without one is refused (403, reason `tenant_missing`). Point `config.base_controller_class` and `config.api_base_controller_class` at a controller that sets the tenant (or set it in middleware), or set `config.admin_tenantless_access = :allow` to serve tenant-less requests across every tenant. See [multi-tenancy.md](multi-tenancy.md).
3. **`nested_attributes_parent_fallback` is `false`.** A `<assoc>_attributes` payload for a child model the user has no Resource entry for is now dropped by `PermitsAttributes`, instead of being filtered against the parent's fields. Add a Resource for the child model to the user's sets, or set the option to `true` (not recommended; reported by `rake permission_forge:audit`).
4. **`NotAuthorizedError#message` is always a String** (the rule failure messages joined by `', '`). Code that read the Array or Hash from `message` must use `#details`, which keeps the value the error was raised with.
5. **RLS users: re-sync the policies** with `rake permission_forge:rls:sync` (`RlsPolicyGenerator::GENERATOR_VERSION` is 5; boot warns about the drift until you do). The `view_all` bypass now requires an active resource row in the row's tenant.
6. **Consider `config.action_guard_nil_user_strategy = :deny`.** New installs get it; existing installs keep following `nil_user_strategy` (default `:bypass`, which lets a request with no user through the controller action guard).
7. **`PermissionForge::Cache::RedisCache` is removed.** It was never loaded. Use `config.cache_backend = :rails_cache` with `redis_cache_store`, or pass an `ActiveSupport::Cache::RedisCacheStore` instance.
8. **Blank names are refused** for Permission Sets, Permission Set Groups, fields and actions when they are created or renamed (422 in the API). Rows whose name is already blank stay editable in their other attributes; rename them.
9. **`user_list_resolver` is now the boundary of the people the admin and the API reach by id.** A person it leaves out is not found (404) on the person page, on assignment (also by assignment id: change of end date, Keep, Remove, Undo), erasure, group membership (also removal by membership id), and on the API's assignment and membership endpoints (`DELETE …/users/:uuid` included). Lists — a set's holders tab, `GET …/users` — still show every holder. The default resolver lists everyone, as before; if yours narrows the list (active users only, say), the people it leaves out can no longer be managed from the admin.
10. **The API's forgery check runs first.** A mutating request without a valid CSRF token reaches `api_auth` with an empty session and cookie jar. Same-origin JavaScript that calls the API with the session must send the `X-CSRF-Token` header; token or API-key clients are unaffected. See [CSRF Posture](admin-api.md#csrf-posture).
11. **Auto-applied masking reaches other processes through the cache store.** When a `Resource` row names a new model, every process masks it at its next request or job, through a token in the cache store. Use a shared store (`:rails_cache` over Redis, Memcached or Solid Cache); under `:memory` or `:null` other processes still pick the model up only at their next boot.

12. **Conditional Permission Sets are evaluated per request.** `request_context_resolver` now runs on every permission read of a user who holds a conditional set: keep it cheap, make it return `{}` where there is no request, and do not read permissions inside it (that raises `ConfigurationError`). In strict mode, conditional muting sets now apply without a request context. See [activation-conditions.md](activation-conditions.md).

### After the deploy: clear the permission cache once

0.14 keeps its entries under a new key namespace (`pf:v2:user_<id>`, `pf:v2:tenant_<t>_user_<id>`, and per-context variants). A 0.14 invalidation also removes the 0.13 keys, but a 0.13 process cannot reach a 0.14 entry: during a rolling deploy, a permission change made by a 0.13 process can stay cached in 0.14 until `cache_ttl`. Once **the last 0.13 process is gone**, run:

```bash run
ACTOR="ops: deploy" REASON="deploy 0.14" bin/rails permission_forge:cache:clear
```

- It removes every user's cached permissions in every tenant (both versions' keys and the variants). Where the store can delete by pattern (Redis, memory and file stores) it does so in one call per namespace, after checking with canary keys that the pattern reaches the store's keys; otherwise (Memcached, Solid Cache, or a pattern that did not reach the keys) it invalidates every user of the user model, per tenant when tenancy is on.
- Running it before the last 0.13 process stops does not help: an invalidation that process makes afterwards misses the new entries again.
- The cache is cold afterwards: each user rebuilds once, on their next request. Expect that load right after.
- It is recorded as `cache.cleared` (one event per tenant plus one without a tenant; see [audit-log.md](audit-log.md)).
- 0.15 no longer removes the 0.13 keys on invalidation: an app still on 0.13 upgrades through 0.14 (see [Upgrading to 0.15](#upgrading-to-015)).

## Upgrading to 0.13: the audit log

Version 0.13 adds the [audit event log](audit-log.md): an `audit_events` table that is insert-only through the model (save, update and destroy raise; `update_all`, `delete_all` and `AuditEvent.delete` still work from Ruby — protect it [at database level](audit-log.md#protecting-the-table-at-database-level)), written in the transaction of every change made through the models, plus an admin page, exports and an API endpoint to read it. See [what is not recorded](audit-log.md#what-is-not-recorded).

### Steps

```bash fragment
bin/rails generate permission_forge:upgrade --skip   # reads your table prefix; add --tenant-column=<col> if your tables are tenant-scoped
bin/rails db:migrate
```

1. The generator adds the migrations you do not have yet (the resource-field unique index, the admin-UI columns, the audit log). `--skip` leaves earlier migrations alone: without it, an earlier `add_resource_fields_unique_index` migration that is not byte-identical stops the generator with a conflict. The unique-index migration is guarded, so the upgrade also runs on installs that already have that index (every install from 0.11 on).
2. The audit migration creates `audit_events` and adds `permission_set_users.reviewed_at`, `reviewed_by_id`, `reason`, `permission_set_group_users.reason` and `resource_fields.sensitive_acknowledged_by_id`. It is guarded and can be re-run. It is **irreversible**: `down` raises `ActiveRecord::IrreversibleMigration`, because the audit log is evidence.
3. A fresh `install` takes `--tenant=Model`; the upgrade takes `--tenant-column=<column>` (default: the configured tenant column).
4. `reviewed_by_id` and `sensitive_acknowledged_by_id` take the type of your existing `permission_set_users.user_id` column, and the audit table's tenant column the type of your tenant column, so UUID and string keys need no edit (repair a `bigint` `user_id` first: see [UUID or string keys](#uuid-or-string-keys)).
5. Set `config.audit_actor_resolver` so events name a person (see [Who did it](audit-log.md#who-did-it-actor-resolution)).
6. Protect the table at database level, set `audit_retention_period` and schedule the purge ([audit-log.md](audit-log.md#what-the-host-must-do)).

Until the migration has run, `audit_events = :auto` (the default) keeps everything working without recording, logs a warning at boot, and `rake permission_forge:audit` reports `audit_table_missing`. A worker started before the migration starts recording within 60 seconds of it.

### Behaviour changes

- **Every change is an event, and a change fails if its event cannot be written** (`audit_change_failure_strategy = :raise`). To keep the old behaviour of "the change always succeeds" choose `:report` or `:log`; the security audit then reports `audit_changes_unrecorded`.
- **Views and exports fail closed too.** Viewing someone's effective access, the audit tabs and the log are recorded with the same strategy; under `:raise` a view whose event cannot be written answers 500 and shows nothing.
- **`updated_by` is no longer blanked.** An edit by nobody (a console, a job), by an HTTP Basic login or by an API client used to set `updated_by_id` to `nil`; it now keeps the previous editor. `created_by_id` is stamped on create and `updated_by_id` on create and on each update, only from an actor that is a record of `audit_user_class`. "Last edited by" in the admin now comes from the latest change event (the row can pair an older editor with a newer `updated_at`).
- **Staleness is counted from the last review, not from `updated_at`.** "Keep" now sets `reviewed_at` and `reviewed_by_id`; editing an assignment no longer counts as a review. Existing rows are not backfilled, so after the upgrade every permanent assignment is stale-eligible from its grant date. `StaleAssignmentAuditor` rows gain `last_reviewed_at` and `reviewed_by_id`; `days_stale` follows the review; `last_updated` is kept.
- **`NotAuthorizedError` has readers.** `#user`, `#record` and `#record_id` (the record is `nil` when the gem raises: the denied row is not loaded). `ActionNotAuthorizedError` gains `#user` and `#record`. Existing `new(details)` calls keep working.
- **`config.audit_runtime_events` is frozen.** `config.audit_runtime_events << :bypass` raises `FrozenError`; assign a new array: `config.audit_runtime_events = %i[denied bypass]`.
- **`on_rule_bypass` and `on_field_filtered` keep their signatures but are now subscribers** of `rule.bypassed` and `field.access`. Their errors are no longer swallowed: they follow `audit_hook_failure_strategy` (default `:report`: logged and handed to `Rails.error`). Under `:raise` a hook error propagates out of the read or the query that triggered it and replaces the decision's own outcome. `on_field_filtered` is called once per field decision, in the same order with the same arguments: as the decision is made when it is the only listener and `field_read` is not stored (as before), otherwise when the read returns.
- **Cloning and group deletion.** A copy of a Permission Set or group credits the person making it (fresh uuid, `created_by` / `updated_by` reset) and is created unlocked rather than unlocked afterwards. Deleting a group detaches its sets through saves (one `permission_set.updated` each) instead of `dependent: :nullify`.
- **Association writers run callbacks.** `user.permission_sets.delete(set)`, `set.user_ids = []`, `group.permission_sets = []`, `clear` and `delete_all` without an argument on the gem's collections now remove assignments, memberships and set links record by record, each with an event and a cache invalidation (they used to be one SQL statement with neither). Passing the strategy explicitly (`delete_all(:delete_all)`) or narrowing the relation (`where(...).delete_all`) is still plain SQL and is not recorded. Destroying a user, set or group never destroys the other side.
- **Consent withdrawal is one transaction** with its revocations and its `consent.withdrawn` summary: if the summary cannot be written under `:raise`, nothing is revoked.
- **`on_field_filtered` is called for `record.attributes` with no current user**, as it already was for getters and `as_json`.
- **Field sync, Review-and-save and `generate_fields` are all-or-nothing** and share one correlation id.
- **Rake tasks** that change data take `ACTOR=` and `REASON=` (a warning is printed without `ACTOR`); report tasks record `report.generated`. New: `rake permission_forge:audit_events:purge`.
- **CSV exports of a person or Permission Set are no longer capped** at 500 rows per type.
- **`admin_assignment_authorization`** is new: `->(controller, target, user_ids, action)`. Refusals of it, and of `audit_log_authorization`, are recorded.
- **Boot warnings**: audit switched off, a shared Basic-auth login without `audit_actor_resolver`, and a missing table.

### `rake permission_forge:audit` and `FAIL_ON`

The audit gains an `audit_trail` check ([security-audit.md](security-audit.md)). A CI step that gated on a level may now fail on an upgrade:

- `FAIL_ON=high`: an app that has not run the migration (`audit_table_missing`, High), or has `audit_events = false` (`audit_off`), or holds self-granted access (`audit_self_granted`).
- `FAIL_ON=medium` or `low`: also a default install using HTTP Basic auth without `audit_actor_resolver` (`audit_shared_basic_auth`, Medium) or with the API enabled and no resolver (`audit_anonymous_api`, Medium) until you set the resolver, any app with `unknown`-actor change events in the last 30 days (`audit_unknown_actors`, Medium), and `audit_change_failure_strategy` other than `:raise` (`audit_changes_unrecorded`, Medium).
- `FAIL_ON=low`: also `audit_hook_failure_strategy = :log` (`audit_hook_failures_logged`, Low).
- The Info findings fail a build only under `FAIL_ON=info` or (up to 0.14) an unrecognised `FAIL_ON` value, which counted as `info`. From 0.15 `FAIL_ON` is read in any case and an unrecognised value exits 2.

## UUID or string keys

Columns that store one of *your* primary keys — `user_id`, the audit columns `created_by_id` / `updated_by_id`, and the tenant column added by `--tenant` — must have the type of that key. The install generator reads the key type from your user model (and tenant model) and types the columns to match:

```bash fragment
bin/rails generate permission_forge:install                       # detected from User
bin/rails generate permission_forge:install --user-id-type=uuid   # explicit: bigint, integer, uuid or string
bin/rails generate permission_forge:install --tenant=Account --tenant-id-type=uuid
```

Run the generator after your users table exists so detection can work; when it cannot read the key type it assumes `bigint` and says so.

**Why it matters.** An integer column silently truncates a UUID to its leading digits (`1aaaaaaa-…` and `1bbbbbbb-…` both become `1`), so users who share those digits would share permission sets. Versions up to 0.12.2 always created `bigint` columns. From 0.13.0 the gem refuses to work on such a schema: reading permissions or writing an assignment raises `PermissionForge::ConfigurationError` naming each column. It is raised at the point of use, not at boot, so `db:migrate` can still run to repair it.

**Repairing an affected install.** The stored ids are truncated and cannot be mapped back to users, so the assignments have to be re-created after the columns are retyped:

```ruby fragment
class RetypePermissionForgeUserKeys < ActiveRecord::Migration[7.1]
  PREFIX = 'permission_forge_'
  ASSIGNMENTS = { permission_set_users: %i[permission_set_id idx_pf_pset_users_unique],
                  permission_set_group_users: %i[permission_set_group_id idx_pf_pset_group_users_unique] }.freeze
  TABLES = %w[permission_set_groups permission_sets resources resource_fields resource_actions
              permission_set_rules permission_set_users permission_set_group_users].freeze

  def up
    ASSIGNMENTS.each do |name, (parent_key, unique_index)|
      table = :"#{PREFIX}#{name}"
      execute "DELETE FROM #{table}"
      remove_index table, name: unique_index.to_s
      remove_column table, :user_id
      add_column table, :user_id, :uuid, null: false
      add_index table, :user_id
      add_index table, [parent_key, :user_id], unique: true, name: unique_index.to_s
    end

    TABLES.each do |name|
      %i[created_by_id updated_by_id].each do |column|
        remove_column :"#{PREFIX}#{name}", column
        add_column :"#{PREFIX}#{name}", column, :uuid
      end
    end
  end
end
```

Use `:string` instead of `:uuid` for string keys, and your own prefix. If you have already run the 0.13 upgrade, retype `permission_set_users.reviewed_by_id` and `resource_fields.sensitive_acknowledged_by_id` the same way. Then assign people to their permission sets again.

## Upgrading an Existing Install to 0.10.0+

Version 0.10.0 added schema hardening that new installs now get automatically from the install migration: unique indexes on `resource_fields (resource_id, name)`, `permission_set_users (permission_set_id, user_id)`, and `permission_set_group_users (permission_set_group_id, user_id)`, plus matching model uniqueness validations.

If you installed with an earlier version, run the upgrade generator:

```bash fragment
bin/rails generate permission_forge:upgrade
```

This creates a migration that de-duplicates any existing `(resource_id, name)` collisions in `resource_fields` — keeping the most-restrictive row (masked over unmasked, then no-edit over edit) — and adds the unique index that new installs get by default. Duplicate field rows are a security issue: a duplicate with `mask_access: false` could silently unmask the field via the mask AND-merge logic.

The generator reads your app's configured `config.table_name_prefix` (the initializer is loaded by `rails generate`), so the migrations target your real tables — including unprefixed ones — without extra flags. To override, pass `--table-prefix`:

```bash fragment
bin/rails generate permission_forge:upgrade --table-prefix=""
```

> Before 0.12.1 the default was always `permission_forge_`; apps on another prefix had to pass the flag or the migration failed with `relation "permission_forge_resource_fields" does not exist`. If you generated with the wrong prefix, delete the unapplied migration files and run the generator again.

This also applies if you migrated from an embedded implementation with `--skip-migration` (below) — your legacy tables likely lack these indexes.

## Migrating from an Embedded Implementation

If you already have permission tables in your database (e.g., `permission_sets`, `resources`, etc.):

1. Install without migration:
   ```bash fragment
   rails generate permission_forge:install --skip-migration --table-prefix=""
   ```

2. Update your configuration to use empty prefix:
   ```ruby fragment
   config.table_name_prefix = ''
   ```

3. Replace concern includes:
   ```ruby fragment
   # Before
   include PermissionsGenerator
   include PermissionsHelpers

   # After
   include PermissionForge::Concerns::PermissionedUser
   ```

4. Replace model references:
   ```ruby fragment
   # Before                              # After
   Users::PermissionSet           =>     PermissionForge::PermissionSet
   Users::Resource                =>     PermissionForge::Resource
   Users::ResourceField           =>     PermissionForge::ResourceField
   Users::PermissionSetRule       =>     PermissionForge::PermissionSetRule
   Users::PermissionSetUser       =>     PermissionForge::PermissionSetUser
   Users::PermissionSetGroup      =>     PermissionForge::PermissionSetGroup
   Users::PermissionSetGroupUser  =>     PermissionForge::PermissionSetGroupUser
   ```

5. Run your test suite to verify everything works.
