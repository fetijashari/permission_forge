# Multi-Tenancy (acts_as_tenant)

## Overview

PermissionForge integrates with the [acts_as_tenant](https://github.com/ErwinM/acts_as_tenant) gem to provide full multi-tenant isolation. When enabled, all 8 permission models are scoped to the current tenant — permission sets, resources, fields, actions, rules, and user assignments are completely isolated between tenants.

## Setup

### 1. Install acts_as_tenant

```ruby fragment
# Gemfile
gem 'acts_as_tenant'
```

### 2. Generate the initializer and migration with the tenant

```bash fragment
rails generate permission_forge:install --tenant=Account
```

This writes `config.tenant_model = 'Account'` into the initializer and adds an
indexed `account_id` column to all 8 PermissionForge tables and to the audit log
(`audit_events`). A namespaced tenant model works too: `--tenant=Billing::Account`
still yields `account_id`. The column takes the type of the tenant model's primary
key (`uuid` for UUID-keyed tenants); pass `--tenant-id-type=uuid` to set it yourself.
An integer tenant column holding UUID or string keys is refused at run time
(`HostKeyGuard`, see the [migration guide](migration-guide.md#uuid-or-string-keys)).

### 3. Review the configuration

```ruby fragment
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.tenant_model = 'Account'       # Your tenant model class name (nil disables)
  config.tenant_column = :account_id    # Optional; inferred from the model
end
```

`tenant_column` is passed to `acts_as_tenant` as the foreign key, so a custom
column name (`:org_id`) scopes every query and every cache invalidation on that
column. Boot fails with `PermissionForge::ConfigurationError` when `tenant_model`
is set but the `acts_as_tenant` gem is not loaded — a misconfigured install can
never run with cross-tenant visibility.

### 4. Set current tenant in your app

```ruby fragment
# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  set_current_tenant_through_filter
  before_action :set_tenant

  private

  def set_tenant
    set_current_tenant(current_user.account)
  end
end
```

The admin screens and the admin API do **not** inherit your `ApplicationController` unless you tell them to. Point `config.base_controller_class` (and `config.api_base_controller_class` when the API is on) at a controller that sets the tenant (for example the `ApplicationController` above, or an admin base controller that calls `set_current_tenant`), or set the tenant in middleware.

With `tenant_model` set, a request that reaches the admin or the API with no current tenant is refused (403, recorded as `admin.auth_failed` / `api.auth_failed`, reason `tenant_missing`). `config.admin_tenantless_access = :allow` serves such requests: they read, edit and delete existing records of **every** tenant, but creating a record still needs a tenant (refused as invalid). Boot logs a warning, and `rake permission_forge:audit` reports `tenantless_admin`, while a base controller is still `ActionController::Base`. Recommended: `ActsAsTenant.configure { |c| c.require_tenant = true }`.

## How It Works

### Automatic Query Scoping

When `config.tenant_model` is set, all PermissionForge models get `acts_as_tenant` applied via the `HasTenantScoping` concern. This means:

- `PermissionForge::PermissionSet.all` only returns sets for the current tenant
- Creating a new record automatically sets the `account_id`
- Cross-tenant queries are impossible through normal ActiveRecord methods

### Tenant-Aware Cache Keys

Cache keys include the tenant ID to prevent cross-tenant cache collisions:

```ruby fragment
# Without tenant: "v2:user_42"
# With tenant:    "v2:tenant_1_user_42"
```

In the store they sit under `cache_key_prefix` (`pf:v2:tenant_1_user_42` by default). A user with conditional permission sets also has per-context variants under the same key plus `_c_<1..63>` (a slot per combination of sets; see [activation-conditions.md](activation-conditions.md#what-is-cached)).

This means the same user can have different cached permissions in different tenants.

Invalidation is tenant-aware too (v0.10.0+): `user.invalidate_permissions(tenant_id: ...)` deletes the given tenant's cache key alongside the ambient and tenant-agnostic keys (per-context variants are left to their TTL, unreachable without the base entry), and permission-record callbacks pass the changed record's tenant id automatically. Cross-user permission changes invalidate the affected users' entries rather than eagerly rebuilding them — the hash is rebuilt lazily (read-through) in each user's own request context.

A change in tenant A therefore retires only tenant A's entry; tenant B's cached hash for the same user is untouched. This holds when the change is made from a request with tenant A set and when it is made from a job or console with no tenant at all (the tenant id comes from the changed record).

### Tenant-Safe PermissionScopedFindable

The `find_by` override in `PermissionScopedFindable` preserves tenant scoping in its fallback queries. The fallback always uses `where(nil).find_by(...)` instead of `unscoped.find_by(...)` (v0.10.0+), which keeps both acts_as_tenant's tenant scope and any host `default_scope` (e.g. soft-delete) intact — preventing cross-tenant data leaks.

## Cross-Tenant User Sharing

An owner who manages multiple accounts can assign the same user to permission sets in different tenants:

```ruby fragment
# User 42 works in both Account A and Account B

ActsAsTenant.current_tenant = account_a
ps_a = PermissionForge::PermissionSet.find_by(name: 'Sales Team')
PermissionForge::PermissionSetUser.create!(user: user, permission_set: ps_a)
user.can_read?(:Customer)
# The first check builds and caches: v2:tenant_1_user_42 -> { Customer: { read: true } }

ActsAsTenant.current_tenant = account_b
ps_b = PermissionForge::PermissionSet.find_by(name: 'Admin')
PermissionForge::PermissionSetUser.create!(user: user, permission_set: ps_b)
user.can_delete?(:Customer)
# v2:tenant_2_user_42 -> { Customer: { read: true, delete: true } }
```

No `regenerate_permissions` is needed: each assignment invalidates the user's cached hash after the commit, and the next check rebuilds it.

Each tenant context produces a separate permission hash. The user sees different permissions depending on which tenant they're currently operating in.

## What Gets Scoped

All 8 PermissionForge models are tenant-scoped:

| Model | Scoped |
|-------|--------|
| PermissionSet | Yes |
| PermissionSetUser | Yes |
| PermissionSetGroup | Yes |
| PermissionSetGroupUser | Yes |
| Resource | Yes |
| ResourceField | Yes |
| ResourceAction | Yes |
| PermissionSetRule | Yes |

Services that query these models are automatically scoped via the default scope:
- `DashboardStats` — counts per-tenant
- `ExpiredAssignmentCleaner` — cleans per-tenant
- `GdprFieldAuditor` — audits per-tenant
- `BulkPermissionSetAssignment` — assigns per-tenant

The admin UI and the JSON API act inside the request's tenant: lists show one tenant, another tenant's ids and uuids are a 404 on every verb, and records created there are stamped with that tenant. `acts_as_tenant` also rejects cross-tenant references (an assignment to another tenant's set, a resource on another tenant's set, a set joining another tenant's group) with a validation error.

Your users table is not one of these models. If it is not tenant-scoped, scope `config.user_list_resolver` to the current tenant's users: it is the boundary of the people the admin and the API can reach by id (a person it leaves out is a 404), not only the picker list.

## Running Without a Tenant (jobs, console, rake)

`acts_as_tenant` treats "no current tenant" as "see everything". For PermissionForge that means:

- **Reads** use the tenant-agnostic cache key `v2:user_<id>` and the hash is the **union of the user's grants in every tenant**. Only reach this path deliberately (reports, maintenance); set `ActsAsTenant.current_tenant` in jobs and consoles that act for one tenant. To fail closed instead, `ActsAsTenant.configure { |c| c.require_tenant = true }` makes a tenant-less `permissions_hash` raise `ActsAsTenant::Errors::NoTenantSet`.
- **Writes** fail validation (`Account must exist`): a permission record can only be created while a tenant is set, so NULL-tenant rows cannot appear by accident.
- **Maintenance** (`rake permission_forge:cleanup_expired_assignments`, `permission_forge:erasure`, `stale_assignments`, a consent withdrawal run from a console) spans every tenant when run without one, also under `require_tenant = true`: the services lift acts_as_tenant's scope for that run. Each destroyed assignment still retires its own tenant's cache key and writes its `assignment.revoked` in that tenant. The run's summary (`cleanup.expired_assignments`, `consent.withdrawn`) is written in each tenant concerned and once without a tenant. Run from the admin UI, the same actions stay inside the admin's tenant.
- **Erasure label scrub.** `DataSubjectErasure` clears the person's name labels in the current tenant's audit events when a tenant is set (the admin UI), and in every tenant's events, and the events without a tenant, when none is set (the rake task).

## Destroying a User

Destroying a user (a model with `PermissionedUser`) while a tenant is set also removes their assignments and group memberships in **every other tenant**, each through its callbacks with its own tenant set: one audit event per row in its tenant, and that tenant's cache entry invalidated. With no tenant set, the user's associations already reach every tenant's rows.

## Row-Level Security (PostgreSQL)

With tenancy on, the generated RLS policies tie the `view_all` bypass to the row's tenant: a `view_all` grant in tenant A never bypasses the rules on tenant B's rows. A row whose tenant column is NULL never gets the bypass. If the protected table has no tenant column, the tenant predicate is omitted and a `view_all` grant in any tenant bypasses the rules on that table. After upgrading to 0.14, re-sync the policies (`rake permission_forge:rls:sync`, `GENERATOR_VERSION` 5). See [query-scoping.md](query-scoping.md).

## Backward Compatibility

- `config.tenant_model = nil` (default) — **no multi-tenancy, zero changes**
- No runtime dependency on acts_as_tenant unless configured
- All existing tests continue to pass without modification
- Rows whose tenant column is NULL (data that predates tenancy) are **hidden under every tenant** and visible only while no tenant is set — backfill the column before turning tenancy on

## Tests

`test/permission_forge/tenancy/` covers row isolation across all 8 models, per-tenant cache invalidation (including changes made with no tenant set), `PermissionScopedFindable` on a tenant-scoped host model, API and admin UI isolation, and the configuration/generator surface.
