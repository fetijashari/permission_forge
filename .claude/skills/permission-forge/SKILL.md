---
name: permission-forge
description: Add PermissionForge permissions to a model — scaffolds concerns, resources, fields, rules, and tests
argument-hint: "<ModelName> [options: --with-rules --with-fields --grant-all --test-only]"
allowed-tools: Read, Write, Edit, Grep, Glob, Bash, Agent
---

# PermissionForge — Add Permissions to a Model

You are helping a developer add PermissionForge permissions to a model in their Rails app.

## Arguments

- `$0` = Model name (e.g., `Customer`, `Article`, `Supplier`)
- Remaining args may include flags:
  - `--with-rules` — also create example row-level rules
  - `--with-fields` — also auto-generate resource fields
  - `--grant-all` — grant full read/edit access on generated fields
  - `--test-only` — only generate test helpers, no model changes
  - `--remove` — remove PermissionForge from a model
  - `--status` — show current permission setup for the model
  - `--debug` — diagnose permission issues for the model

Full input: $ARGUMENTS

## Steps

### 1. Understand the Model

Read the model file to understand:
- What columns it has
- What associations it has (needed for join-based rules)
- Whether it already includes any PermissionForge concerns
- What the table name is

### 2. Based on the Action

**Default (add permissions):**

a) Add `include PermissionForge::Concerns::PermissionScopedFindable` to the model (if not present)
b) Ensure the User model includes `PermissionForge::Concerns::PermissionedUser` (if not present)
c) Check that `config.current_user_resolver` returns the signed-in user. The generated initializer has `-> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }`: it works when the app has a `Current` (ActiveSupport::CurrentAttributes) with a `user` that is set per request, and returns nil otherwise. Until it returns a user, nobody is signed in: `nil_user_strategy` decides for rules and masking (under the default `:bypass` both are skipped), and `PermitsAttributes` drops every key. If the app has no such `Current`, write the resolver for the app's own authentication
d) Create a seed/migration snippet that:
   - Creates a `PermissionForge::Resource` for the model
   - Optionally generates `ResourceField` records for all columns
   - Optionally creates example `PermissionSetRule` records
e) Show the developer what access checks are now available, and say that rules apply only through class-level `Model.find_by` / `Model.find_by!` and `Model.permission_scoped` unless `auto_query_scoping` is on (see Architecture below)
f) Generate a spec file testing the permission setup

**`--status`:**
Show what PermissionForge setup exists for this model:
- Is PermissionScopedFindable included?
- Do Resource/ResourceField records exist? (check seeds or migrations)
- Are there any PermissionSetRule examples?

**`--debug`:**
Help diagnose permission issues:
- Check the cached hash via `user.permissions_hash` (read-through — a cache miss rebuilds automatically; permission changes invalidate affected users via `after_commit`)
- Use `PermissionForge::Concerns::MaskedAttributes.explain(record, :field)` / `.explain_all(record)` to trace per-field decisions
- Check cache backend configuration
- Verify Resource/ResourceField records exist for the model
- Check if PermissionScopedFindable is included
- Look for NotAuthorizedError rescues in controllers

**`--remove`:**
Remove PermissionForge from a model:
- Remove the `include` statement
- Warn about orphaned Resource/ResourceField/Rule records

### 3. Output

Always show a summary of what was done and what the developer should do next:
- Run migrations (if any)
- Seed permission data
- Nothing to regenerate: permission and assignment changes invalidate the affected users' caches after commit and `permissions_hash` rebuilds read-through on the next read. Do not add `regenerate_permissions` calls to seeds, controllers or tests
- Test the setup

## Reference

### PermissionForge Architecture

3-tier permissions:
1. **Resource CRUD** — Can user read/create/edit/delete this model?
2. **Field-level** — Can user read/edit specific columns? Are they masked?
3. **Row-level rules** — Which specific rows can user access? (via the class-level `Model.find_by` / `Model.find_by!` overrides and the chainable `Model.permission_scoped` relation — `find_by` on a relation or association, `where`, `find` and `all` do not apply rules; optionally enforced on ALL queries via `config.auto_query_scoping = :filter_only`, detected via `config.unscoped_query_detection`, and/or enforced in Postgres via RLS — see docs/query-scoping.md)

Plus: **Custom resource actions** — admin-defined actions (sync, export, approve) checked via `can?(action, resource)`.

### Multi-Permission-Set Merging

Users can belong to multiple permission sets. Sets are partitioned into **granting** (`is_muting: false`) and **muting** (`is_muting: true`).

**Granting phase** (additive, most-permissive-wins):
- Resource CRUD / field read/edit: **TRUE wins** — if any granting set allows, user has it
- mask_access: **FALSE wins among the rows that grant read** — if any read-granting row unmasks a field, user sees full value; a Hidden row (read off) never votes, so Masked in one set and Hidden in another stays masked
- Resource action is_permitted: **TRUE wins** — if any granting set permits, user can perform action
- Rules: **accumulative** — all rules from all granting sets apply together, so they intersect: adding a set with a rule narrows the rows another set allowed (a `view_all` on the resource lifts them)

**Muting phase** (subtractive, deny overrides allow):
- Resource CRUD / view_all / modify_all: set to `false` if muting resource has it as `true`
- Resource read muted: every field of that resource (variants and implicit virtual fields included) loses read and edit
- Field read/edit: set to `false` if muting field has it as `true` — muting a field also revokes its configured variants (e.g. `user_id` → `user_uuid`, `price_cents` → `price`)
- Field mask_access: forced to `true` if muting field has `mask_access: true`
- Action is_permitted: set to `false` if muting action has `is_permitted: true`
- Rules: muting sets do NOT add rules

**Admin warning:** Granting sets cannot revoke each other's flags or fields (their row rules do intersect), but muting sets can revoke anything.

### Assignment Expiration

Permission set assignments can be time-bound via `expires_at`:

```ruby
PermissionForge::PermissionSetUser.create!(
  user: user, permission_set: ps,
  expires_at: 1.week.from_now  # nil = never expires
)
```

Expired assignments are excluded from the permission hash on every rebuild, and the cache TTL is clamped to the soonest assignment `expires_at` so an expired assignment never keeps granting from the shared cache. A user instance that memoized its hash stops granting from it at the soonest `expires_at` too (the memo is retired then). Use `ExpiredAssignmentCleaner.call` to remove stale records in bulk.

### Activation Conditions

Permission sets can have runtime activation conditions:
- `requires_session_flag: 'mfa_verified'` — only active in requests whose context carries the flag
- `allowed_ips: '192.168.1.0/24, 10.0.0.0/8'` — only active from allowed IPs
- `allowed_hours_start: 9, allowed_hours_end: 17` — only active during business hours

Configure `config.request_context_resolver` to provide `{ ip:, session_flags:, time: }`. Conditions are checked on every permission read, against the request that reads (the cache keeps a base entry plus one variant per combination of passing conditional sets), so the resolver runs on every read of a user with conditional sets: keep it cheap, return `{}` where there is no request, and never read permissions inside it (that raises `ConfigurationError`). Without a resolver (blank context), conditional sets are treated as active by default. Set `config.conditional_sets_strict_mode = true` to fail closed: with no request context (neither an IP nor session flags) conditional granting sets are dropped and conditional muting sets still apply. See `docs/activation-conditions.md`.

### Multi-Tenancy (acts_as_tenant)

```ruby
config.tenant_model = 'Account'       # nil = disabled (default)
config.tenant_column = :account_id    # optional, inferred from model
```

When enabled, all 8 models get `acts_as_tenant` applied. Cache keys include tenant ID (`v2:tenant_1_user_42`). Same user can have different permissions per tenant. Generate with `rails g permission_forge:install --tenant=Account`.

### Admin JSON API

PermissionForge includes built-in RESTful JSON endpoints. Enable with:

```ruby
config.api_enabled = true
config.api_auth = ->(_controller) { PermissionForge.current_user&.has_role?(:admin) } # set when api_base_controller_class signs the caller in
config.api_record_identifier = :uuid
# Authorization hooks (api_auth proves identity, these prove admin-ness):
config.api_action_authorization = ->(controller, action, record) { ... }      # gates create/update/destroy/clone
config.api_assignment_authorization = ->(controller, target, user_ids) { ... }  # gates assignment/revoke; target is a PermissionSet or PermissionSetGroup, user_ids an Array
config.api_require_authorization = true  # the default: 403 while the hooks above are unset
```

**Endpoints** (under engine mount + `/api/`):
- `GET/POST /api/permission_sets` + `GET/PATCH/DELETE /:identifier` + `POST /:identifier/clone`
- `GET/POST /api/permission_sets/:ps/resources` + `GET/PATCH/DELETE /:identifier` + `POST /:identifier/generate_fields`
- Nested: `/fields`, `/actions`, `/rules` under resources
- `GET/POST/DELETE /api/permission_sets/:ps/users`
- `GET/POST /api/permission_set_groups` + `GET/PATCH/DELETE /:identifier` + `POST /:identifier/clone` + nested `/users`
- `GET /api/stats` — dashboard counts

**Response format:** `{ data: {...} }` or `{ data: [...], meta: { pagination: {...} } }`
**Error format:** `{ error: { status: 422, messages: {...} } }`

Supports AMS serializer overrides via `config.api_serializer_overrides = { permission_set: MySerializer }`.

**Cache invalidation:** All API mutations (create/update/destroy) automatically invalidate the cached permissions of affected users via `after_commit` callbacks; the hash rebuilds on the next read (`permissions_hash` is read-through). No manual `regenerate_permissions` call needed after API changes. Records flagged `is_editable: false` are locked, together with what they hold (a locked Permission Set takes no new resources, fields, rules or actions) — those mutations return 403 (`admin.lock_refused`); a change to its holders passes only when it narrows access (on a granting set: removing holders, shortening end dates; on a Muting Permission Set: adding holders, extending end dates).

### Key Files in This Gem

- `lib/permission_forge/concerns/permission_scoped_findable.rb` — Row-level enforcement (class-level `find_by`, `find_by!`, `permission_scoped`)
- `lib/permission_forge/concerns/auto_permission_scoping.rb` — Level 1 auto-scoping default_scope hook (`auto_query_scoping = :filter_only`)
- `lib/permission_forge/services/unscoped_query_detector.rb` — Level 2 unscoped-query detection (`unscoped_query_detection = :log/:raise`)
- `lib/permission_forge/rls.rb` + `lib/permission_forge/services/rls_policy_generator.rb` — Level 3 Postgres RLS (generator, `rls:sync`/`rls:status` rake tasks, `RLS.with_user`)
- `lib/permission_forge/concerns/permissioned_user.rb` — User access methods (`can?`, `masked_field?`, `mask_strategy_for`, `field_permissions`)
- `lib/permission_forge/concerns/masked_attributes.rb` — Model-level masking of direct attribute readers (auto-applied to models with a Resource record)
- `lib/permission_forge/services/resource_field_generator.rb` — Auto-generate fields (with optional GDPR defaults)
- `lib/permission_forge/services/permits_attributes.rb` — Write-path: filter params by field edit access (nested `<assoc>_attributes` against the child model's own resource entry)
- `lib/permission_forge/services/filters_response_attributes.rb` — Read-path: filter + mask response attributes by read/mask access
- `lib/permission_forge/services/mask_value.rb` — Apply masking strategies: `full`, `email`, `last4`, `first1_last4`
- `lib/permission_forge/services/gdpr_field_auditor.rb` — Scan existing fields for unmasked GDPR-sensitive data
- `app/controllers/permission_forge/api/` — 10 JSON API controllers (the read-only `audit_events` included) and their base controller
- `lib/permission_forge/api/serializers/` — 10 lightweight built-in serializers plus `BaseSerializer`
- `app/models/permission_forge/` — All 8 permission models (including `ResourceAction`)
- `config/locales/` — 3 locale files (en, sq, mk) under `permission_forge:` namespace

### I18n

All admin UI strings use `t()` calls. 3 locales ship built-in. Admin UI has a locale switcher in the sidebar. API accepts `?locale=` param or `Accept-Language` header. When adding new UI strings, add keys to all 3 locale files. Run `bundle exec i18n-tasks health` to verify.

### Masked Attributes

Fields can be masked instead of hidden. Set `mask_access: true` and `mask_strategy` on a ResourceField.

**Precedence:** `read_access: false` → hidden. `read_access: true, mask_access: true` → masked. `read_access: true, mask_access: false` → full.

```ruby
# Check masking at runtime
user.masked_field?(:ModelName, :email)      # => true/false
user.mask_strategy_for(:ModelName, :email)  # => 'email'

# Apply mask to a value
PermissionForge::Services::MaskValue.call('john@example.com', strategy: 'email')
# => "j***@example.com"
```

When `config.gdpr_defaults = true`, `ResourceFieldGenerator` auto-masks PII fields at creation time. Use `GdprFieldAuditor.call` to find unmasked GDPR fields.

Since v0.9, the `MaskedAttributes` concern auto-applies to any model with a `Resource` record (`config.auto_apply_masked_attributes`, default `:auto`), so direct AR readers (`customer.email`), `attributes`, and `as_json` are enforced too — `pluck` and raw SQL are not. Unconfigured fields follow `config.unconfigured_field_strategy` (default `:block`, fail closed). Masked values can't be persisted back (`config.masked_write_protection`, default `:skip`). Debug field decisions with `PermissionForge::Concerns::MaskedAttributes.explain(record, :email)` or `.explain_all(record)`.

### Write Path (PermitsAttributes)

```ruby
safe = PermissionForge::Services::PermitsAttributes.call(resource: ModelName, permitted_params: model_params)
record.update!(safe)
```

- Pass params you have already permitted (`params.require(:model_name).permit(...)`): the result is a plain Hash, which Rails' mass-assignment protection no longer checks.
- A key is kept only when the user may edit that field; its value (a Hash or Array in a json column) is not looked into. No signed-in user: every key is dropped.
- A nested `<assoc>_attributes` payload (only for associations declared with `accepts_nested_attributes_for`) is filtered against the **child model's own** resource entry. If the user's hash has no entry for the child model, the payload is dropped: `config.nested_attributes_parent_fallback` is `false` by default. Setting it to `true` filters the payload against the parent's fields instead, as versions before 0.14 did; keep it `false` (the security audit reports it).
- A nested record keeps its `id` only when the id names a row the child model's rules let the user reach (or the child has no row rules); otherwise the whole record is dropped. A nested record without an id is a new record.

### Log Parameter Filtering

PermissionForge can redact GDPR-sensitive fields from Rails logs via `filter_parameters` integration:

```ruby
# Automatic (enabled by default)
config.filter_parameters_integration = true  # default: true (also requires gdpr_defaults = true, the default)

# Manual
Rails.application.config.filter_parameters += PermissionForge.gdpr_filter_parameters
```

### Custom Resource Actions

```ruby
# Create a custom action
PermissionForge::ResourceAction.create!(
  resource: resource, name: 'export', label: 'Export to CSV',
  is_permitted: true, is_active: true
)

# Check at runtime (the creation invalidated the holders' caches)
user.can?(:export, :ModelName)  # => true
user.can?(:read, :ModelName)    # => delegates to can_read?
```

### Example Seed Snippet

```ruby
# Create a permission set first (Resource belongs_to a permission set)
permission_set = PermissionForge::PermissionSet.find_or_create_by!(name: 'Default Set') do |ps|
  ps.is_active = true
end

# Create resource — name must be written as a Ruby constant path
# (e.g. Customer or Admin::Report). Only the format is validated, no class is
# looked up: check the spelling. Unique per permission set.
resource = PermissionForge::Resource.find_or_create_by!(permission_set: permission_set, name: 'ModelName') do |r|
  r.label = 'Model Name'
  r.read_access = true
  r.create_access = true
  r.edit_access = true
  r.delete_access = false
  r.is_active = true
end

# Auto-generate fields (with GDPR masking if config.gdpr_defaults = true).
# Note: (resource_id, name) is unique — duplicate field rows are rejected.
PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: true)

# Create custom actions
PermissionForge::ResourceAction.create!(resource: resource, name: 'export', is_permitted: true)

# Create a rule (optional)
PermissionForge::PermissionSetRule.create!(
  permission_set: permission_set,
  resource: resource,
  name: 'Own records only',
  field_name: 'user_id',
  field_value: 'current_user',
  operator: PermissionForge::PermissionSetRule::EQUAL,
  # join_type: leave nil for a filter on the model's own table
  # ('joins', 'left_joins' or 'left_outer_joins' for a rule across an association)
  is_active: true,
  failure_message: 'You can only access your own records'
)
```

### Example Test

Use the app's own way of building a user (a factory or fixture); the gem's test helpers are not available in a host app. `uuid` columns are filled automatically. No `regenerate_permissions` is needed: each change invalidates the holders' caches, which also retires the hash memoized on `@user`.

```ruby
class ModelNamePermissionsTest < ActiveSupport::TestCase
  setup do
    @user = users(:one) # or your factory
    @permission_set = PermissionForge::PermissionSet.create!(name: 'Test', is_active: true)
    @resource = PermissionForge::Resource.create!(permission_set: @permission_set, name: 'ModelName', read_access: true, is_active: true)
    PermissionForge::PermissionSetUser.create!(user: @user, permission_set: @permission_set)
  end

  test 'grants read access' do
    assert @user.can_read?(:ModelName)
  end

  test 'denies delete access' do
    refute @user.can_delete?(:ModelName)
  end

  test 'checks custom actions' do
    PermissionForge::ResourceAction.create!(resource: @resource, name: 'export', is_permitted: true)
    assert @user.can?(:export, :ModelName)
  end

  test 'checks masked fields' do
    PermissionForge::ResourceField.create!(resource: @resource, name: 'email',
           read_access: true, mask_access: true, mask_strategy: 'email')
    assert @user.masked_field?(:ModelName, :email)
  end
end
```

## Table Name Prefix

All 9 PermissionForge tables (the 8 permission tables and `audit_events`) are prefixed by default with `permission_forge_` (e.g., `permission_forge_permission_sets`).

- **Configuration:** `config.table_name_prefix = 'permission_forge_'` (default)
- **Generator:** `rails generate permission_forge:install --table-prefix=pf_` for custom prefix
- **No prefix:** `rails generate permission_forge:install --table-prefix=''` for existing apps
- **Dynamic:** Models use `def self.table_name` methods, so the configured prefix is read when the models are used, not frozen when they load. Set it in the initializer; changing it at run time is not supported (ActiveRecord caches the Arel table)
- **Tests:** Test suite uses empty prefix (`''`) for simplicity
- **Existing installs:** `bin/rails generate permission_forge:upgrade --skip` adds the migrations an install does not have yet (the `resource_fields (resource_id, name)` unique index with de-duplication, the admin-UI columns, the audit log); accepts the same `--table-prefix` option
