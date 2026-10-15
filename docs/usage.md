# Usage

## Multi-Permission-Set Merging

Users can belong to multiple permission sets. When granting permission sets have conflicting access flags on the same resource, field, or action, **the most permissive value wins** (TRUE takes priority).

> **Admin Warning:** Be careful when assigning users to multiple permission sets. If **any** granting permission set grants a resource, field or action flag, the user has it — another granting set cannot revoke it. Resource, field and action flags are the **union** of all assigned granting sets. **Row-level rules are the opposite: they intersect.** The rules of every granting set apply together, so adding a set that has a rule on a model narrows the rows another set allowed (unless some set grants `view_all` / `modify_all` there, which bypasses every rule). To *subtract* flags, use a [muting permission set](muting-permission-sets.md) (`is_muting: true`) — muting sets are applied after the granting merge and can revoke any flag.

**Merge rules (granting sets):**

| Component | Merge logic | Example |
|-----------|------------|---------|
| Resource CRUD (`read_access`, etc.) | TRUE wins | "Sales" denies delete + "Admin" grants delete → user **can** delete |
| Field `read_access` / `edit_access` | TRUE wins | "Sales" hides email + "Support" shows email → user **can see** email |
| Field `mask_access` | Decided by the rows that grant read; among them FALSE wins (unmasked = more permissive). A Hidden row never votes | "Sales" masks email + "Admin" unmasks → user sees **full** email. "Sales" masks email + "Support" hides it → **masked** |
| Field `mask_strategy` | The first read-granting row's strategy | When all sets mask, the first such set's strategy is used |
| Resource action `is_permitted` | TRUE wins | "Sales" denies export + "Admin" permits → user **can** export |
| Row-level rules | Accumulative (intersect) | Rules from **all** sets are combined and all must pass — a set with a rule narrows what another set allowed |

Muting sets (`is_muting: true`) are applied **after** this granting merge and subtract access (they never add rules) — see [Muting Permission Sets](muting-permission-sets.md). Sets are merged in a deterministic order (`created_at`, then `id`), so "first mask_strategy wins" is stable across requests.

```ruby
# Example: User with two permission sets
# "Sales Team" — read + create customers, mask email
# "Admin" — full CRUD, unmask email, can export

# Effective permissions for user in both sets:
user.can_read?('Customer')            # => true  (from either set)
user.can_delete?('Customer')          # => true  (from Admin)
user.masked_field?(:Customer, :email) # => false (Admin unmasks → FALSE wins)
user.can?(:export, :Customer)         # => true  (from Admin)
```

## Setting Up Permissions

```ruby
# Create a permission set
pset = PermissionForge::PermissionSet.create!(name: 'Admin', is_active: true)

# Add a resource with full CRUD
resource = PermissionForge::Resource.create!(
  permission_set: pset,
  name: 'Customer',
  read_access: true, create_access: true,
  edit_access: true, delete_access: true
)

# Auto-generate field permissions from model columns: grant_all gives read and
# edit on every field, unmasked (personal-data columns included)
PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: true)

# Or grant full access in one call (creates resource + fields, no masks)
PermissionForge::Resource.grant_full_access!(permission_set: pset, resource_name: 'Customer')

# Assign a user — takes effect at the user's next permission read
PermissionForge::PermissionSetUser.create!(permission_set: pset, user: user)
```

No refresh call is needed: creating, changing or removing permission records and assignments through ActiveRecord invalidates the affected users' cached permissions after the commit, and the next read rebuilds them.

## ViewAll / ModifyAll

ViewAll and ModifyAll are resource-level permissions that bypass all row-level rules on that resource (either flag bypasses them for `find_by` and `permission_scoped` alike). When enabled, the user sees all records regardless of ownership rules.

```ruby
resource = PermissionForge::Resource.create!(
  permission_set: pset,
  name: 'Customer',
  read_access: true, create_access: true,
  edit_access: true, delete_access: true,
  view_all: true,    # Bypasses row-level rules
  modify_all: true   # Same effect on the rules; requires view_all
)

# Check at runtime
user.can_view_all?(:Customer)   # => true
user.can_modify_all?(:Customer) # => true
```

> **Note:** `modify_all` requires `view_all` to be enabled (enforced by validation).

## Dependency Validations

PermissionForge enforces logical dependencies between permission flags at the model level:

| Rule | Applies to | Reason |
|------|-----------|--------|
| `edit_access` requires `read_access` | Resource, ResourceField | Cannot edit what you can't see |
| `delete_access` requires `read_access` | Resource | Cannot delete what you can't see |
| `modify_all` requires `view_all` | Resource | Cannot modify all if you can't view all |
| `mask_access` requires `read_access` | ResourceField | Cannot mask a field that isn't readable |

These validations are enforced on save. Attempting to create a resource with `edit_access: true, read_access: false` will raise a validation error.

## Bulk User Assignment

Assign or revoke multiple users at once — each user whose assignment changed has their cached permissions invalidated once, after the commit, and rebuilt read-through on their next permission read:

```ruby
PermissionForge::Services::BulkPermissionSetAssignment.call(
  permission_set: pset,
  user_ids: [1, 2, 3, 4, 5],
  action: :assign  # or :revoke
)
```

## Checking Permissions

```ruby
# Resource-level checks
user.can_read?('Customer')    # => true
user.can_create?('Customer')  # => true
user.can_edit?('Customer')    # => true
user.can_delete?('Customer')  # => true

# Aliases
user.can_show?('Customer')     # same as can_read?
user.can_update?('Customer')   # same as can_edit?
user.can_destroy?('Customer')  # same as can_delete?

# Generic can? — works for CRUD and custom actions
user.can?(:read, :Customer)    # => true (delegates to can_read?)
user.can?(:export, :Customer)  # => true (checks custom resource action)

# Get full permission data
user.permissions_for(:Customer)
# => { read_access: true, create_access: true, edit_access: true, delete_access: true,
#      view_all: false, modify_all: false }

user.permissions_hash_for(:Customer)
# => { permissions: {...}, fields: {...}, actions: {...}, source_permission_sets: [...], permission_set_rules: [...] }
```

## Custom Resource Actions

Beyond CRUD, admins can define custom actions per resource. These are fully configurable through the database — no code changes required.

To have controller actions checked automatically instead of calling `can?` by hand, and to list your app's controller actions in the admin, see [Controller Actions](controller-actions.md).

```ruby
# Admin creates custom actions for a resource
PermissionForge::ResourceAction.create!(
  resource: resource,
  name: 'export',
  label: 'Export to CSV',
  is_permitted: true,
  is_active: true
)

PermissionForge::ResourceAction.create!(
  resource: resource,
  name: 'sync',
  label: 'Sync to ERP',
  is_permitted: false,
  is_active: true
)

# Check custom actions at runtime (no refresh call needed)
user.can?(:export, :Customer)  # => true
user.can?(:sync, :Customer)    # => false

# CRUD actions also work through can?
user.can?(:read, :Customer)    # => true (delegates to can_read?)
user.can?(:update, :Customer)  # => true  (delegates to can_edit?; the set above grants edit)
```

## Field-Level Permissions

```ruby
# Get field permissions from the cached hash (here with a `name` row and the masked,
# read-only `email` row created under "Masked Attributes" below)
entry = user.permissions_hash_for(:Customer)
fields = entry[:fields]
# => {
#      name:  { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' },
#      email: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }
#    }

# Check if a specific field is editable
fields[:email][:edit_access]  # => false

# Convenience helpers for field-level access
user.field_permissions(:Customer, :email)
# => { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' }
```

## Masked Attributes

Field masking provides a middle ground between fully visible and fully hidden. When `mask_access: true`, the field value is obfuscated instead of hidden entirely.

**Precedence:**
- `read_access: false` — field hidden entirely (not in response)
- `read_access: true, mask_access: true` — field shown but value is masked
- `read_access: true, mask_access: false` — field shown in full

**4 built-in masking strategies:**

| Strategy | Input | Output |
|----------|-------|--------|
| `full` | `anything` | `********` |
| `email` | `john@example.com` | `j***@example.com` |
| `last4` | `+1234567890` | `*******7890` |
| `first1_last4` | `John Smith` | `J*****mith` |

```ruby
# Configure masking on a resource field
PermissionForge::ResourceField.create!(
  resource: resource,
  name: 'email',
  label: 'Email',
  read_access: true,
  edit_access: false,
  mask_access: true,
  mask_strategy: 'email'
)

# Check if a field is masked
user.masked_field?(:Customer, :email)        # => true
user.mask_strategy_for(:Customer, :email)    # => 'email'

# Since v0.9.0, direct AR readers route through masking automatically when the
# MaskedAttributes concern is applied (auto-applied by default to every model
# with a Resource record — see masked-attributes.md):
customer.email  # => "j***@example.com"

# Manual masking (only needed when config.auto_apply_masked_attributes is disabled):
value = raw_email_value  # => "john@example.com"
if user.masked_field?(:Customer, :email)
  strategy = user.mask_strategy_for(:Customer, :email)
  value = PermissionForge::Services::MaskValue.call(value, strategy: strategy)
  # => "j***@example.com"
end
```

> **Note:** For fields with no `ResourceField` entry, `masked_field?` follows `config.unconfigured_field_strategy` — it reports the field as masked under `:block` / `:mask_all` (fail closed, v0.10.0+).

## Privacy Defaults

When `config.gdpr_defaults = true` (the default since v0.5.0), the `ResourceFieldGenerator` automatically applies masking to fields matching known privacy-sensitive patterns. This only applies at field **creation** time — it never overwrites admin changes.

Full access is the exception (since 0.15.0): `ResourceFieldGenerator.call(grant_all: true)`, `Resource.grant_full_access!`, `ResourceWithFieldsBuilder`, the API's `generate_fields` with `grant_all` and the admin's "Full access" preset apply no mask. The fields are still flagged as personal data — `GdprFieldAuditor` / `rake permission_forge:audit_masks` report them as `unmasked_field`, and the admin's Home lists them under "Privacy audit" — so you decide, field by field, which to mask (or confirm "This is intended"). The recommended strategy is stored on the row (`mask_strategy`), so masking it later uses the right one.

> **Important:** Masking provides display-level obfuscation only — it does NOT constitute GDPR-compliant anonymization or pseudonymization. See [GDPR Masking Disclaimer](gdpr_masking_disclaimer.md) for details.

```ruby
# gdpr_defaults is true by default since v0.5.0
# To opt out:
PermissionForge.configure do |config|
  config.gdpr_defaults = false
end

# With gdpr_defaults enabled (the default), auto-generated fields get masks applied
PermissionForge::Services::ResourceFieldGenerator.call(resource: resource)
# email field → read_access: true, mask_access: true, mask_strategy: 'email'
# phone field → read_access: true, mask_access: true, mask_strategy: 'last4'
# name field  → read_access: true, mask_access: true, mask_strategy: 'first1_last4'
# (other fields: no access)

# Full access applies no mask; the recommended strategy is kept for later
PermissionForge::Services::ResourceFieldGenerator.call(resource: resource, grant_all: true)
# email field → read_access: true, edit_access: true, mask_access: false, mask_strategy: 'email'
```

**Built-in privacy patterns** (`DEFAULT_GDPR_FIELD_PATTERNS`):

| Pattern | Fields Matched | Strategy |
|---------|---------------|----------|
| `email`, `*_email` | email, work_email, billing_email | `email` |
| `*phone*`, `*telefon*`; `tel`, `fax`, `mobile` as a name segment | phone, mobile_phone, home_tel, fax_number, telNumber | `last4` |
| `ssn`, `social_security*`, `national_id` | ssn, social_security_number | `last4` |
| `*iban*`, `*bank_account*`, `*credit_card*` | iban, bank_account_number | `last4` |
| `name`, `first_name`, `last_name`, `full_name` | name, contact_name | `first1_last4` |
| `*address*`, `*street*`, `*postal*`; `city`, `zip` as a name segment | street_address, home_city, zipcode, postal_code | `full` |
| `date_of_birth`, `birthday`; `dob` as a name segment | date_of_birth, dob | `full` |
| `ip_address`, `ip` | ip_address | `full` |
| `*ethnic*`, `*telegram*` | ethnicity, telegram_handle | `full` |

A name segment is delimited by `_`, the ends of the name, a digit or a camelCase capital: `hotel_id`, `capacity` and `telemetry_enabled` do not match, nor does a stem glued to another word (`homecity`, `telno`); add a pattern for such names.

**Extend or override patterns:**

```ruby
PermissionForge.configure do |config|
  config.gdpr_defaults = true
  config.gdpr_field_patterns = PermissionForge::Configuration::DEFAULT_GDPR_FIELD_PATTERNS.merge(
    /tax_id|vat_number/ => 'last4'
  )
end
```

**Audit existing fields for privacy gaps:**

```ruby
# Returns both unmasked fields AND unmapped model columns matching GDPR patterns.
# Only rows in effect count (active row, active resource, active granting set):
# a switched-off row is reported as unmapped, not as unmasked.
report = PermissionForge::Services::GdprFieldAuditor.call
# => [
#      { type: :unmasked_field, resource_field_id: 42, field_name: 'email',
#        resource_name: 'Customer', suggested_strategy: 'email', permission_set: 'Sales Team' },
#      { type: :unmapped_column, resource: 'Customer', column: 'phone',
#        pattern_matched: 'last4' },
#      # a declared virtual field with no row, readable and editable by default
#      { type: :implicit_virtual_grant, resource_name: 'Customer', field_name: 'full_address',
#        suggested_strategy: 'full', permission_set: 'Sales Team' },
#      ...
#    ]
```

**Run the audit from the command line (CI-friendly):**

```bash
bundle exec rake permission_forge:audit_masks
# Exits with status 1 if issues found — integrate into your CI pipeline
```

The auditor is read-only — it reports gaps for admin review without auto-fixing, preserving intentional admin overrides.

**Detect GDPR pattern drift:**

```ruby
# After changing gdpr_field_patterns, check if re-generation is needed
PermissionForge.configuration.gdpr_patterns_changed_since_generation?
# => true (patterns changed since last ResourceFieldGenerator run)
```

### Log Parameter Filtering

PermissionForge can automatically redact GDPR-sensitive fields from Rails logs and error reporters by appending its patterns to `Rails.application.config.filter_parameters`.

```ruby
# Automatic (enabled by default — set to false to opt out)
PermissionForge.configure do |config|
  config.gdpr_defaults = true
  config.filter_parameters_integration = true  # default
end

# Or manual (one-liner in your filter_parameter_logging initializer)
Rails.application.config.filter_parameters += PermissionForge.gdpr_filter_parameters
```

This uses the same `gdpr_field_patterns` as masking — single source of truth. See [GDPR Masking Disclaimer](gdpr_masking_disclaimer.md) for details.

## Row-Level Rules

Row-level rules are applied when a model includes `PermissionScopedFindable` and you go through the class-level `Model.find_by` / `Model.find_by!` or `Model.permission_scoped` (or turn on `auto_query_scoping`; see [Query scoping](query-scoping.md)). A user with no rules for a model sees every row.

```ruby
# Create a rule: users can only see their own records
PermissionForge::PermissionSetRule.create!(
  permission_set: pset,
  resource: resource,
  name: 'Own Records Only',
  failure_message: 'You can only view your own records',
  field_name: 'owner_id',
  field_value: 'current_user',     # Substituted with the current user's id at runtime;
                                   # any other value is compared in the column's type, and
                                   # one the column cannot hold makes the rule match nothing
  operator: 'equal',
  include_nulls: true              # Also match NULL values
)

# Now the class-level find_by enforces the rule
Customer.find_by(uuid: 'abc')   # => nil when no such record exists (stock Rails contract);
                                #    raises NotAuthorizedError only when the record exists
                                #    but a rule denies access
Customer.find_by!(uuid: 'abc')  # Same, but raises ActiveRecord::RecordNotFound when missing

# For collections, start from permission_scoped (v0.10.0+) — the rules stay
# applied through any further chaining (.where, .order, .first, .count)
Customer.permission_scoped.where(active: true).count

# Not scoped with the default auto_query_scoping :off:
# Customer.where(...).find_by(...), supplier.customers.find_by(...), Customer.find(id), Customer.all
```

**Available operators:** `equal`, `not_equal`, `less_than`, `greater_than`, `less_than_or_equal`, `greater_than_or_equal`, `in`, `not_in`, `contains`, `not_contains`, `starts_with`, `ends_with`, `between`, `is_null`, `is_not_null`

**Values** are typed for the column they are compared with — a number, a boolean (`yes`, `off`, ...), an ISO 8601 date, an enum label — so a rule selects the same rows on PostgreSQL, MySQL and SQLite. See [How Values Are Compared](row-level-rules.md#how-values-are-compared).

**Join types for nested associations:**

```ruby
PermissionForge::PermissionSetRule.create!(
  # ...
  join_type: 'left_joins',              # or 'joins', 'left_outer_joins'
  field_accessor_path: 'organization.members.user',  # Nested association path
  field_name: 'id',
  field_value: 'current_user'
)
```

## Filtering Attributes

### Write-Path: `PermitsAttributes`

Strip fields the user cannot edit (used in commands/controllers on incoming params):

```ruby
params = { name: 'New Name', email: 'new@mail.com', secret: 'hidden' }
filtered = PermissionForge::Services::PermitsAttributes.call(
  resource: customer,          # An instance of the model
  permitted_params: params
)
# => { name: 'New Name' }  (only fields with edit_access: true)
```

`PermitsAttributes` never mutates the params you pass in — it returns a new plain Hash (v0.10.0+), so pass params you have already permitted. A key the user may not edit is dropped whatever its value. A `<assoc>_attributes` payload, for an association the model `accepts_nested_attributes_for`, is filtered against the association model's own resource; when the user has no entry for that model the payload is dropped (unless `config.nested_attributes_parent_fallback = true`), and a nested record's `id` must name a row the child model's rules let the user reach. See [Nested attributes](field-filtering.md#nested-attributes).

### Read-Path: `FiltersResponseAttributes`

Strip fields the user cannot read and mask sensitive fields (used in serializers/views on outgoing data):

```ruby
attributes = { name: 'Acme', email: 'john@example.com', secret: 'classified', domain: 'acme.com' }
filtered = PermissionForge::Services::FiltersResponseAttributes.call(
  attributes: attributes,
  resource_name: 'Customer'
)
# => { name: 'Acme', email: 'j***@example.com' }
#    - 'name' kept as-is (read_access: true, mask_access: false)
#    - 'email' masked (read_access: true, mask_access: true, strategy: 'email')
#    - 'secret' removed (read_access: false)
#    - 'domain' removed (not configured — unconfigured_field_strategy defaults to :block)
```

**Behavior:**
- Fields with `read_access: false` are removed
- Fields with `read_access: true, mask_access: true` are masked using the configured strategy
- Fields not in the permission hash follow `config.unconfigured_field_strategy` (default `:block` — removed from the response; unknown strategy values also fall back to `:block`)
- Fails closed for authenticated users: a user with no configured access to the resource gets **every** field routed through `unconfigured_field_strategy` — never the raw attributes (v0.10.0+)
- With no current user, behavior follows `config.response_filter_nil_user_strategy`: `:bypass` (default) returns the attributes unfiltered, `:block` returns `{}`. Model masking follows `config.masked_attributes_nil_user_strategy` (`:bypass` default / `:hide`)

**Serializer integration example:**

```ruby
class BaseSerializer < ActiveModel::Serializer
  def filter_attributes(hash, model_name)
    PermissionForge::Services::FiltersResponseAttributes.call(
      attributes: hash,
      resource_name: model_name
    )
  end
end
```
