<p align="center">
  <img alt="PermissionForge" src="https://raw.githubusercontent.com/fetijashari/permission_forge/main/docs/assets/logo-horizontal-light.svg#gh-light-mode-only" width="420">
  <img alt="PermissionForge" src="https://raw.githubusercontent.com/fetijashari/permission_forge/main/docs/assets/logo-horizontal-dark.svg#gh-dark-mode-only" width="420">
</p>

<p align="center">
  <a href="https://github.com/fetijashari/permission_forge/actions/workflows/ci.yml"><img src="https://github.com/fetijashari/permission_forge/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://rubygems.org/gems/permission_forge"><img src="https://img.shields.io/gem/v/permission_forge" alt="Gem Version"></a>
  <a href="https://scorecard.dev/viewer/?uri=github.com/fetijashari/permission_forge"><img src="https://api.scorecard.dev/projects/github.com/fetijashari/permission_forge/badge" alt="OpenSSF Scorecard"></a>
  <a href="https://www.bestpractices.dev/projects/15499"><img src="https://www.bestpractices.dev/projects/15499/badge" alt="OpenSSF Best Practices"></a>
  <a href="https://rubydoc.info/gems/permission_forge"><img src="https://img.shields.io/badge/docs-rubydoc.info-blue.svg" alt="API documentation"></a>
  <a href="https://www.ruby-lang.org"><img src="https://img.shields.io/badge/ruby-%3E%3D%203.2-ruby.svg" alt="Ruby"></a>
  <a href="https://rubyonrails.org"><img src="https://img.shields.io/badge/rails-7.1%20to%208.1-red.svg" alt="Rails"></a>
  <a href="https://github.com/fetijashari/permission_forge/blob/main/LICENSE.txt"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
</p>

<p align="center">
  Database-backed permissions for Ruby on Rails.<br>
  Resource CRUD and custom actions, field-level read/edit access with masking, and row-level query rules, edited at runtime and cached per user.
</p>

---

## Overview

PermissionForge implements a **three-tier permission model**:

| Tier | Scope | Controls |
|------|-------|----------|
| **Resource** | Model | Can this user read/create/edit/delete Customers? Run the `export` action? |
| **Field** | Column | Can this user see `email`? Masked or in full? Edit `name`? |
| **Rule** | Row | Only records where `owner_id = current_user.id` |

Permissions live in your database as **Permission Sets** (collections of resources, fields, actions and rules) that are
assigned to users, optionally grouped, and edited in the built-in admin while the app runs. Each user's merged
permissions are cached as one hash.

### Features

- **Resource-level CRUD and custom actions** per model (`can_read?`, `can?(:export, :Customer)`), and an optional
  controller guard that checks them before an action runs ([Controller Actions](https://github.com/fetijashari/permission_forge/blob/main/docs/controller-actions.md))
- **Field-level read/edit access**, enforced on the model's attribute readers and serialization (`MaskedAttributes`), on
  incoming params (`PermitsAttributes`) and on response hashes (`FiltersResponseAttributes`)
- **Field masking** with four built-in strategies (`full`, `email`, `last4`, `first1_last4`) and your own
- **Row-level query rules**: 15 operators, 3 join types, values compared in the column's type on PostgreSQL, MySQL and
  SQLite; applied by `Model.find_by` / `find_by!` and `Model.permission_scoped`
- **Optional query scoping**: a `default_scope` for every query, detection of queries that skipped the rules, and
  PostgreSQL Row-Level Security policies ([Query Scoping](https://github.com/fetijashari/permission_forge/blob/main/docs/query-scoping.md))
- **Muting Permission Sets** that subtract access, **time-bound assignments**, and **activation conditions** (session
  flag, IP allowlist, login hours), evaluated for each request
- **Audit log** of every permission change made through the models, written in the change's transaction
- **Admin UI** with no host asset dependencies, and an **opt-in JSON admin API**
- **Personal-data helpers**: masks suggested for personal-data columns when fields are generated, a field auditor, and
  log parameter filtering for those columns (on by default)
- **Any Rails cache store** (`Rails.cache` over Redis, Solid Cache, Memcached, file; or in-memory for tests)
- **Multi-tenancy** through `acts_as_tenant`, and three locales (English, Albanian, Macedonian)
- **No hard dependencies** on Devise, Pundit, Rolify or any auth framework: every integration point is a lambda

### How it differs from Pundit, CanCanCan and Action Policy

Those are policy libraries: you write rules in Ruby and call them where you decide. PermissionForge is a permissions
platform: rules are data that admins edit at runtime, and the gem hooks into your app to apply them. It overrides
`find_by` on models you protect, wraps attribute readers and serialization, can add a `default_scope`, runs checks at
boot, and mounts an admin. That reaches further than a policy library and couples more tightly to your models; it can
sit next to one (for example Pundit for controller decisions, PermissionForge for fields and rows).

---

## Installation

Add to your `Gemfile`:

```ruby
gem 'permission_forge'
```

Then run:

```bash
bundle install
bin/rails generate permission_forge:install
bin/rails db:migrate
```

This creates `config/initializers/permission_forge.rb` and a migration with 9 tables: the 8 permission tables and the
audit log, prefixed with `permission_forge_` by default.

Then mount the admin UI and give it credentials. It is behind HTTP Basic auth and answers 401 until both are set:

```ruby
# config/routes.rb
mount PermissionForge::Engine, at: "/permissions"
```

```ruby
# config/initializers/permission_forge.rb: uncomment Option A ("Admin screens")
config.http_basic_auth_user     = ENV['PF_ADMIN_USER']
config.http_basic_auth_password = ENV['PF_ADMIN_PASSWORD']
```

Set `PF_ADMIN_USER` and `PF_ADMIN_PASSWORD` in the environment and open `/permissions`. To sign admins in with your
own authentication instead, see [Admin UI](https://github.com/fetijashari/permission_forge/blob/main/docs/admin-ui.md#disabling-http-basic-auth)
(`base_controller_class`). `bin/rails permission_forge:audit` lists what is still open before production.

Generator options:
- `--skip-migration`: no migration (for apps with existing tables)
- `--table-prefix=PREFIX`: table name prefix (default `permission_forge_`; `''` for none)
- `--user-id-type=TYPE`: type of the user id columns, `bigint`, `integer`, `uuid` or `string` (default: detected from
  your user model's primary key, so run the generator after your users table exists)
- `--tenant=MODEL`: add a tenant column for [multi-tenancy](https://github.com/fetijashari/permission_forge/blob/main/docs/multi-tenancy.md)
  (`--tenant-id-type=TYPE` to override its detected type)

Requirements: Ruby 3.2+, Rails 7.1 to 8.1, PostgreSQL, MySQL or SQLite.

Upgrading? Read the [CHANGELOG](https://github.com/fetijashari/permission_forge/blob/main/CHANGELOG.md) and the
[migration guide](https://github.com/fetijashari/permission_forge/blob/main/docs/migration-guide.md).

---

## Quick Start

### 1. Tell it who is signed in

The generated initializer reads `Current.user` when your app has a `Current` class that answers `user` (as Rails 8's
authentication generator creates). Otherwise point it at your own lookup:

```ruby
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.user_class = 'User'
  # As generated; or however your app knows the user
  config.current_user_resolver = -> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }
  config.cache_backend = :rails_cache
end
```

Until it returns a user, nobody is signed in and `nil_user_strategy` decides (see the checklist below).

Configure PermissionForge in `config/initializers` only. The gem's models (`PermissionForge::PermissionSet`, ...) are
autoloaded by your application right after the initializers and read `user_class`, `audit_user_class` and
`tenant_model` as they load; a setting changed later (in `after_initialize`, a console) does not reach a loaded class
(PermissionForge logs a warning). Reference a model from a method (your models, controllers, jobs and rake tasks), not
from the top level of an initializer, an engine or railtie initializer, or a file required from
`config/application.rb`: the boot then fails with a `NameError` that says so. To change one of its classes (include a
module, add a callback), use `Rails.application.config.to_prepare` or
`Rails.autoloaders.main.on_load('PermissionForge::PermissionSet')`, which run again after every code reload;
`config.after_initialize` runs once, so use it only to read.

### 2. Include the concern in your User model

```ruby
class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser
end
```

Every private method PermissionForge adds to your User class starts with `pf_`, so a method of your own never
replaces one of the gem's. The public API is the documented one (`permissions_hash`, `regenerate_permissions`,
`invalidate_permissions`, `permission_cache_key`, `permission_invalidation_stamp`, `can?`, `can_*?`,
`permissions_for`, `permissions_hash_for`, `masked_field?`, `mask_strategy_for`, `field_permissions`); override
those, not the private helpers.

### 3. Protect models with row-level rules (optional)

```ruby
class Customer < ApplicationRecord
  include PermissionForge::Concerns::PermissionScopedFindable
end
```

This applies the user's rules to the class-level `Customer.find_by` / `find_by!` and adds a chainable
`Customer.permission_scoped` relation. Nothing else is scoped by default: `find`, `where`, `scope.find_by` and
association traversal return every row. Start from `permission_scoped`, or turn on one of the
[query-scoping levels](https://github.com/fetijashari/permission_forge/blob/main/docs/query-scoping.md). A user with no
rules for a model gets every row.

### 4. Create a Permission Set and assign it

```ruby
pset = PermissionForge::PermissionSet.create!(name: 'Sales Team', is_active: true)

resource = PermissionForge::Resource.create!(
  permission_set: pset,
  name: 'Customer',
  read_access: true, create_access: true,
  edit_access: true, delete_access: false
)

PermissionForge::ResourceField.create!(
  resource: resource, name: 'name', label: 'Name',
  read_access: true, edit_access: true
)

user = User.first # the person who gets the set
PermissionForge::PermissionSetUser.create!(permission_set: pset, user: user)
```

Only `name` has a field row here. A column with no row is refused by the default
`unconfigured_field_strategy = :block`: its getter returns `nil` and `as_json` keeps the key as `null` (a Hidden row,
read off, leaves the key out). `PermissionForge::Services::ResourceFieldGenerator.call(resource: resource)`, or the
admin's "Sync fields with model", gives every column a row (Hidden; timestamps read-only; columns that look like personal
data readable and masked, under the default `gdpr_defaults`); then open the ones the set should read.

Each change invalidates the cached permissions of the users it affects; the next read rebuilds them. The admin UI
(mounted at `/permissions` in [Installation](#installation)) does the same through forms.

Every change is also an audit event. Made in a console, a seed or a script, it is recorded with actor `unknown`;
wrap it to say who and why: `PermissionForge.with_audit_actor(user: admin, reason: 'onboarding') { ... }` (see
[Audit Log](https://github.com/fetijashari/permission_forge/blob/main/docs/audit-log.md)).

### 5. Check permissions at runtime

```ruby
user = User.first # the person you assigned in step 4
user.can_read?('Customer')   # => true
user.can_delete?('Customer') # => false
user.permissions_for(:Customer)
# => { read_access: true, create_access: true, edit_access: true, delete_access: false,
#      view_all: false, modify_all: false }
```

Resource CRUD flags are answers to these calls. They do not by themselves stop a getter or `find_by`: enforce them
where you call `can_*?`, or with `ControllerActionGuard`. Field access is decided by the field rows.

---

## Production hardening checklist

Several defaults fail open so that installing the gem changes nothing until you configure it. Before production, go
through this list. `bin/rails permission_forge:audit` reports most of these settings.

`config.preset = :strict` closes every row below that a setting can close, except masking with nobody signed in (an
explicit choice: see its row); a setting you make yourself always wins over the preset. New installs get the safe
part (`action_guard_nil_user_strategy = :deny`, `conditional_sets_strict_mode = true`, `cache_backend = :rails_cache`)
and the preset as a commented line with what it costs. The rows that need your code (`base_controller_class`,
`admin_assignment_authorization`, `audit_log_authorization`, `user_active_check`) are not in a preset.
`bin/rails permission_forge:audit` prints the preset and, under `:strict`, every option set looser. See
[Presets](https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md#presets).

| Default | What it means | To close it |
|---|---|---|
| `nil_user_strategy = :bypass` | With no current user (jobs, console, a resolver that returns nil), `find_by`, `permission_scoped`, auto-scoping and the RLS policy apply no rules; so does the controller guard unless `action_guard_nil_user_strategy` is set | `:deny` (not found) or `:raise`. Do not include `PermissionScopedFindable` in the user model: under `:deny` sign-in lookups return nil (`permission_forge:audit` reports `user_model_scoped`) |
| `masked_attributes_nil_user_strategy = :bypass` | Attribute readers, `attributes` and `as_json` of a masked model return the stored values when nobody is signed in, whatever `nil_user_strategy` says | `:hide` (every guarded attribute reads as hidden with no user; the primary key and the raw paths are untouched), and set the current user in the jobs and mailers that read masked models. Not part of `config.preset = :strict`. The user model (`user_class` and its subclasses) stays readable for sign-in; validations read stored values |
| `response_filter_nil_user_strategy = :bypass` | `FiltersResponseAttributes` returns every attribute when there is no user | `:block` |
| `auto_query_scoping = :off` | Only class-level `find_by` / `find_by!` and `permission_scoped` apply row rules | `:filter_only`, and use `permission_scoped` for join rules; consider RLS on PostgreSQL |
| `unconfigured_action_strategy = :allow` | A controller action no Permission Set manages is allowed; unmapped actions are always allowed | `:block` |
| `action_guard_nil_user_strategy = nil` | The guard follows `nil_user_strategy` (`:bypass`) for signed-out requests to mapped actions | `:deny` (new installs get it from the generator) |
| `conditional_sets_strict_mode = false` | With an empty request context (no resolver configured), every conditional Permission Set applies, MFA- or IP-gated grants included | A `request_context_resolver` that returns the request's IP and session flags, and `true`: without a request context, conditional granting sets are then dropped and conditional muting sets still apply |
| `mask_virtual_attributes = false` | Virtual readers (methods, store accessors, attribute-API attributes) are not masked on the model; only `PermitsAttributes` and `FiltersResponseAttributes` apply their field rows | `:auto` (or a list of models), after checking that the models' own callbacks do not need the raw values |
| `extra_fields_default_access = :grant` | A declared virtual field no row configures gets the resource's read and edit access, unmasked | `:unconfigured` |
| `cache_backend = :memory` | Per process: invalidations and auto-applied masking do not reach other processes (boot warning in production) | `:rails_cache` over a shared store (Redis, Solid Cache, Memcached) |
| `http_basic_auth_enabled = true` | Without credentials the admin answers 401 (closed). With credentials it is one shared login with full admin power. With Basic auth off and `base_controller_class` left as `ActionController::Base`, the admin is open to anyone | Set `base_controller_class` to your authenticated admin controller, then turn Basic auth off |
| `admin_assignment_authorization = nil` | Every admin who reaches the admin can assign anyone to anything | A lambda that checks the acting admin |
| `audit_log_authorization = nil` | Every admin (and every API caller `api_auth` admits) can read and export the whole audit log | A lambda that returns exactly `true` for those allowed |
| `base_controller_class` / `api_base_controller_class` | With tenancy on, a request with no current tenant is refused (403) | Controllers that authenticate and set the tenant |
| `user_active_check` | Only reported by the security audit; an inactive user keeps every grant | Revoke the assignments of users you deactivate |

Upgrading from 0.13: once the last 0.13 process is gone, run `bin/rails permission_forge:cache:clear` (see the
[CHANGELOG](https://github.com/fetijashari/permission_forge/blob/main/CHANGELOG.md)).

Already closed by default, keep them so: `api_require_authorization = true` (API changes need
`api_action_authorization` and `api_assignment_authorization`), `admin_tenantless_access = :deny`,
`nested_attributes_parent_fallback = false`, `unconfigured_field_strategy = :block`, and the API is off
(`api_enabled = false`). If you use PostgreSQL RLS, run `bin/rails permission_forge:rls:sync` after each upgrade.

See [Configuration](https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md) for every option.

## What is not intercepted

Masking and row rules work at the model layer. These paths read the database or the raw attributes directly:

- **Values:** `pluck`, `pick`, calculations (`minimum(:email)`, `maximum`, `sum`, `group(:email).count`),
  `select("email AS contact")` and other SQL aliases (also through `find_by_sql`), `connection.select_*`,
  `*_before_type_cast` / `read_attribute_before_type_cast` / `attributes_before_type_cast`, `*_in_database` /
  `attribute_in_database`, `_read_attribute`, `attributes_for_database`, the dirty-tracking helpers (`*_was`,
  `changes`, `changes_to_save`), `Marshal.dump` and `to_yaml` / `YAML.dump`. Use `FiltersResponseAttributes` on
  hashes you build this way.
- **Presence:** `where(email: value).exists?` tells whether a value is stored, and `attribute_present?(:email)`
  answers for the stored value even when the column is hidden (the `email?` reader follows the guard).
- **Rows:** with `auto_query_scoping = :off`, everything except class-level `find_by` / `find_by!` and
  `permission_scoped` (for example `find`, `where`, `scope.find_by`, `association.find_by`). With auto-scoping on,
  `unscoped`, `find_by_sql` and raw SQL still skip it; PostgreSQL RLS covers them for connections that set the user's
  session variable (with `nil_user_strategy = :bypass`, a connection without it sees every row).
- **Writes that skip callbacks** (`update_all`, `delete_all`, raw SQL) are not audited.

Details: [Masked Attributes](https://github.com/fetijashari/permission_forge/blob/main/docs/masked-attributes.md),
[Query Scoping](https://github.com/fetijashari/permission_forge/blob/main/docs/query-scoping.md).

---

## Audit log

Every create, update and destroy, made through the models, of a Permission Set, Resource, field, action, rule, group,
assignment or membership is written to the `audit_events` table inside the change's own transaction. Under the default
`audit_change_failure_strategy = :raise`, a change whose event cannot be written rolls back. Each event stores the
actor, source, request id, IP, an optional reason, a correlation id, and the changes or a snapshot of the deleted row.
Behind your own admin controller (`base_controller_class`) the actor is the user `current_user_resolver` returns.
Under HTTP Basic auth your app's sign-in does not run in the admin, so admins share one login name unless
`audit_actor_resolver` names them:

```ruby
PermissionForge.configure do |config|
  # Rails 8's authentication generator (with Devise: controller.request.env['warden']&.user(:user))
  config.audit_actor_resolver = ->(controller) { Session.find_by(id: controller.request.cookie_jar.signed[:session_id])&.user }
  config.audit_retention_period = 2.years # purge: bin/rails permission_forge:audit_events:purge
end
```

Read it at `<mount path>/audit`, export it as CSV or JSON, or call `GET /api/audit_events`. It supports evidence for
access-control and accountability requirements; it is not a certification. It does not record writes that skip
callbacks or, by default, who read data. The model refuses updates and deletes, but `update_all`, `delete_all` and
direct database access still reach the table, so protect it at database level, forward it, synchronise clocks and set
retention. See [Audit Log](https://github.com/fetijashari/permission_forge/blob/main/docs/audit-log.md).

## Documentation

| Guide | Description |
|-------|-------------|
| [Getting Started](https://github.com/fetijashari/permission_forge/blob/main/docs/getting-started.md) | Install, first Permission Set, first checks |
| [Configuration](https://github.com/fetijashari/permission_forge/blob/main/docs/configuration.md) | Every option and its default |
| [Architecture](https://github.com/fetijashari/permission_forge/blob/main/docs/architecture.md) | Data model, merge rules, cache and invalidation |
| [Usage](https://github.com/fetijashari/permission_forge/blob/main/docs/usage.md) | Checking access, custom actions, fields, masking, rules, filtering |
| [Masked Attributes](https://github.com/fetijashari/permission_forge/blob/main/docs/masked-attributes.md) | Model-level field enforcement and what it does not cover |
| [Field Filtering](https://github.com/fetijashari/permission_forge/blob/main/docs/field-filtering.md) | Read-path and write-path filtering, nested attributes, virtual fields |
| [Row-Level Rules](https://github.com/fetijashari/permission_forge/blob/main/docs/row-level-rules.md) | Operators, join types, association paths, STI |
| [Query Scoping](https://github.com/fetijashari/permission_forge/blob/main/docs/query-scoping.md) | Auto-scoping, unscoped-query detection, PostgreSQL RLS |
| [Muting Permission Sets](https://github.com/fetijashari/permission_forge/blob/main/docs/muting-permission-sets.md) | Subtracting access |
| [Activation Conditions](https://github.com/fetijashari/permission_forge/blob/main/docs/activation-conditions.md) | Session flags, IP allowlists, login hours |
| [Assignment Expiration](https://github.com/fetijashari/permission_forge/blob/main/docs/assignment-expiration.md) | Time-bound assignments and clean-up |
| [Permission Set Groups](https://github.com/fetijashari/permission_forge/blob/main/docs/permission-set-groups.md) | Grouping Permission Sets |
| [Controller Actions](https://github.com/fetijashari/permission_forge/blob/main/docs/controller-actions.md) | Permit or block controller actions per Permission Set |
| [Admin UI](https://github.com/fetijashari/permission_forge/blob/main/docs/admin-ui.md) | Mounting, authentication, screens |
| [Admin JSON API](https://github.com/fetijashari/permission_forge/blob/main/docs/admin-api.md) | Authentication, CSRF, endpoints, pagination, serializers |
| [Audit Log](https://github.com/fetijashari/permission_forge/blob/main/docs/audit-log.md) | What is recorded and what is not, exports, retention, protecting the table |
| [Multi-Tenancy](https://github.com/fetijashari/permission_forge/blob/main/docs/multi-tenancy.md) | `acts_as_tenant` integration |
| [Security Audit](https://github.com/fetijashari/permission_forge/blob/main/docs/security-audit.md) | `rake permission_forge:audit` and its findings |
| [GDPR Data Handling](https://github.com/fetijashari/permission_forge/blob/main/docs/gdpr-data-handling.md) | What the gem evidences and what the host must add |
| [HIPAA](https://github.com/fetijashari/permission_forge/blob/main/docs/hipaa-compliance.md) | Technical safeguards: what the gem evidences and what the host must add |
| [Masking Disclaimer](https://github.com/fetijashari/permission_forge/blob/main/docs/gdpr_masking_disclaimer.md) | Masking is not anonymization |
| [Table Name Prefix](https://github.com/fetijashari/permission_forge/blob/main/docs/table-prefix.md) | Custom prefixes, moving between prefixes |
| [Internationalization](https://github.com/fetijashari/permission_forge/blob/main/docs/i18n.md) | Locales and overrides |
| [Performance](https://github.com/fetijashari/permission_forge/blob/main/docs/benchmarks.md) | Overhead and cache costs |
| [Testing](https://github.com/fetijashari/permission_forge/blob/main/docs/testing.md) | Testing permissions in your app |
| [Migration Guide](https://github.com/fetijashari/permission_forge/blob/main/docs/migration-guide.md) | Upgrading between versions |
| [Tips & Helpers](https://github.com/fetijashari/permission_forge/blob/main/docs/tips-and-helpers.md) | Common patterns and pitfalls |
| [AI assistant instructions](https://github.com/fetijashari/permission_forge/blob/main/docs/claude-instructions.md) | A section to paste into your app's `CLAUDE.md` / `AGENTS.md` |

---

## Versioning and stability

PermissionForge follows [Semantic Versioning](https://semver.org/) and is pre-1.0. Until 1.0, a minor version (0.x.0)
may change defaults and behaviour; every such change is listed under **Changed** in the
[CHANGELOG](https://github.com/fetijashari/permission_forge/blob/main/CHANGELOG.md) with its opt-out and upgrade
steps. Patch versions (0.x.y) only fix bugs. The supported surface is the configuration options, the concerns your
models include, the services documented in the guides, the error classes and the permission hash format
([Architecture](https://github.com/fetijashari/permission_forge/blob/main/docs/architecture.md)). Other classes are
internal and may change in any release: classes marked `@api private` in the source (and hidden in the YARD docs) are
internal. A public API is never renamed or removed in one step: the release that changes it keeps the old name
working for at least one minor version and warns through `PermissionForge.deprecator` (registered with
`Rails.application.deprecators`, so `config.active_support.deprecation` governs it), and the CHANGELOG lists it under
**Deprecated** with the version that removes it. Security fixes go into the latest release only.

## Security

Please report vulnerabilities privately, as described in
[SECURITY.md](https://github.com/fetijashari/permission_forge/blob/main/SECURITY.md).

## Contributing

Bug reports and pull requests are welcome. See
[CONTRIBUTING.md](https://github.com/fetijashari/permission_forge/blob/main/CONTRIBUTING.md) for the setup, the test
suites and the rules the code follows, and the
[Code of Conduct](https://github.com/fetijashari/permission_forge/blob/main/CODE_OF_CONDUCT.md).

## Acknowledgements

PermissionForge's permission model (resource-level CRUD, field-level visibility and row-level query rules) was
inspired by [Salesforce's Profile and Permission Set architecture](https://help.salesforce.com/s/articleView?id=sf.perm_sets_overview.htm&type=5),
adapted for Ruby on Rails.

Built at [Confidee](https://confidee.com), where it controls access across internal operations, customer portals and
supplier portals.

## License

The gem is available as open source under the terms of the
[MIT License](https://github.com/fetijashari/permission_forge/blob/main/LICENSE.txt).
