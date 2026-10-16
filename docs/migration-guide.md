# Migration Guide

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
- The removal of the 0.13 keys on invalidation goes away in 0.15.

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
