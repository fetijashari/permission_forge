# Field-Level Filtering

Field-level permissions let you control which individual columns a user can see or edit. This guide shows you how to use them.

## Why Field-Level Permissions?

Imagine you have a `Customer` model with these fields:
- `name` — everyone can see and edit
- `email` — everyone can see, but only managers can edit
- `credit_limit` — only finance team can see
- `internal_notes` — only admins can see or edit

Without field-level permissions, you'd need complex if/else logic everywhere. With PermissionForge, you define it once and filter automatically.

## Setting Up Field Permissions

### Manual Setup

```ruby
resource = PermissionForge::Resource.create!(
  permission_set: pset,
  name: 'Customer',
  read_access: true,
  edit_access: true
)

# Each field gets its own read/edit flags
PermissionForge::ResourceField.create!(resource: resource, name: 'name', label: 'Name', read_access: true, edit_access: true)
PermissionForge::ResourceField.create!(resource: resource, name: 'email', label: 'Email', read_access: true, edit_access: false)
PermissionForge::ResourceField.create!(resource: resource, name: 'credit_limit', label: 'Credit Limit', read_access: false, edit_access: false)
```

### Auto-Generate from Model Columns

Instead of creating fields one by one, you can auto-generate them:

```ruby
# Creates a ResourceField for every column in the Customer model
# (except ignored fields like id, uuid, password; on a granting set
# created_at / updated_at are at most read-only: read-only with grant_all,
# hidden like the rest without it)
PermissionForge::Services::ResourceFieldGenerator.call(
  resource: resource,
  grant_all: false  # Set to true to grant read+edit on all fields, unmasked
)
```

### One-Line Full Access

For admin-level permission sets:

```ruby
PermissionForge::Resource.grant_full_access!(
  permission_set: admin_pset,
  resource_name: 'Customer'
)
# Creates resource with all CRUD = true AND all fields with read+edit = true, unmasked
# (also the personal-data ones under gdpr_defaults: GdprFieldAuditor still reports them)
```

## Reading Field Permissions

```ruby
entry = user.permissions_hash_for(:Customer)
fields = entry[:fields]

# Check individual fields
fields[:name][:read_access]         # => true
fields[:name][:edit_access]         # => true
fields[:email][:edit_access]        # => false
fields[:credit_limit][:read_access] # => false
```

Field rows decide field access. The resource's own CRUD flags do not hide or open fields in a granting set: a field row with `read_access: true` is readable through the getters and the filters even where the resource's `read_access` is false (check `can_read?` yourself, or use [ControllerActionGuard](controller-actions.md), where the resource flag must be enforced). A **muting** set that revokes the resource's read does hide every field; see [Muting Permission Sets](muting-permission-sets.md#what-gets-muted).

## Several Permission Sets

When a user holds several granting sets that have a row for the same field:

- `read_access` and `edit_access`: any set that grants wins.
- The mask is decided **only by the rows that grant read**. The field is masked when every such row masks it — one read-granting row that unmasks wins — and the strategy is that of the first such row (sets in `created_at`, `id` order, rows within a set in id order). A row that does not grant read (what the admin calls **Hidden**) never votes on the mask.

So a field that is **Masked** in one set and **Hidden** in another is readable and masked, in either set order: the Hidden row adds nothing, the Masked row decides. (Before 0.14 the Hidden row took part in the mask decision and the field came out unmasked.) Two read-granting rows, one Masked and one unmasked, give the unmasked value.

Muting sets are applied after this merge; see [Muting Permission Sets](muting-permission-sets.md).

## Filtering Attributes in Controllers

Use `PermitsAttributes` to automatically strip fields the user can't edit:

```ruby
class CustomersController < ApplicationController
  def update
    customer = Customer.find_by(uuid: params[:uuid])

    # This removes any fields the user doesn't have edit_access for
    safe_params = PermissionForge::Services::PermitsAttributes.call(
      resource: customer,
      permitted_params: customer_params.to_h
    )

    customer.update!(safe_params)
    render json: customer
  end

  private

  def customer_params
    params.require(:customer).permit(:name, :email, :credit_limit, :internal_notes)
  end
end
```

**What happens:**
1. User submits `{ name: "New", email: "new@mail.com", credit_limit: 50000 }`
2. `PermitsAttributes` checks the user's field permissions
3. If user can't edit `email` and `credit_limit`, the result is `{ name: "New" }`
4. Only `name` gets updated
5. The params you pass in are never mutated — a new plain `Hash` is returned (v0.10.0+)

Pass params you have already permitted (`customer_params.to_h`, or the permitted `ActionController::Parameters`). The result is a plain Hash, which Rails' `ForbiddenAttributesProtection` does not check: if you pass unpermitted params, the keys the user may edit reach `update!` without Rails' own permit step.

Without a current user `PermitsAttributes` returns `{}`: every key is dropped. A key the user may not edit is dropped whatever its value — a Hash or an Array under it is a value (a json column), never looked into. The resource may be a record or a model class.

### Telling the user what was not saved

Dropping is silent: the update succeeds with the keys that were kept, and a scaffold then says "Customer was successfully updated." although `status` and `notes` were ignored. Pass `report: true` to learn what was dropped. The call then answers a `PermitsAttributes::Result` instead of the Hash: `params` (the same filtered Hash), `dropped` (the paths of the dropped keys: `status`, `supplier_attributes.secret`, `lines_attributes.*.price`; never their values), `dropped?` and `dropped_fields` (the top-level keys, for a message). Without `report:` the return value is the Hash, as before.

```ruby
def update
  result = PermissionForge::Services::PermitsAttributes.call(
    resource: @customer, permitted_params: customer_params, report: true
  )

  if @customer.update(result.params)
    notice = 'Customer was successfully updated.'
    notice += " Not saved: #{result.dropped_fields.join(', ')}." if result.dropped?
    redirect_to @customer, notice: notice
  else
    render :edit, status: :unprocessable_entity
  end
end
```

Translate the message as you do your others. Better still, do not offer what will be dropped: render a field the user may not edit as read-only text (or leave it out when they may not read it) by asking the same permissions the filter uses:

```erb
<% access = Current.user&.field_permissions(:Customer, :status) || {} %>
<% if access[:edit_access] %>
  <%= form.text_field :status %>
<% elsif access[:read_access] %>
  <p><%= @customer.status %></p>  <%# masked by MaskedAttributes when the field is masked %>
<% end %>
```

`field_permissions` returns `nil` for a field without a row; `PermitsAttributes` drops such a key too.

## Filtering in Serializers

> **Note:** Since v0.9.0, models with the `MaskedAttributes` concern applied (the default via `config.auto_apply_masked_attributes` for every model with a `Resource` record) already filter and mask direct attribute reads and the `attributes` / `as_json` / `serializable_hash` output — see [masked-attributes.md](masked-attributes.md). The manual pattern below is only needed when auto-apply is disabled.

For read access, filter fields before sending the response:

```ruby
class CustomerSerializer
  def initialize(customer, user)
    @customer = customer
    @user = user
  end

  def as_json
    entry = @user.permissions_hash_for(:Customer)
    fields = entry&.dig(:fields) || {}

    result = {}
    @customer.attributes.each do |key, value|
      field_perms = fields[key.to_sym]
      next unless field_perms && field_perms[:read_access]
      result[key] = value
    end
    result
  end
end
```

## Field Variant Mappings

PermissionForge automatically creates permission entries for derived field names:

| Original Field | Auto-Created Variant | Why |
|---------------|---------------------|-----|
| `company_id` | `company_uuid` | APIs often expose UUIDs instead of IDs |
| `price_cents` | `price` | Money fields stored in cents but displayed as dollars |

So when you create a field permission for `company_id`, the user automatically gets the same permission for `company_uuid`.

Muting permission sets follow the same mappings (v0.10.0+): a muting set that revokes `company_id` also revokes `company_uuid`, and revoking `price_cents` also revokes `price`.

A variant gets an entry in the permission hash only when the model has that name (0.15+): a column or `attribute`, an `alias_attribute`, a public reader or writer (`delegate :uuid, to: :company, prefix: true` defines `company_uuid`), or a declared virtual field (`extra_fields_for_permissions`). A `Customer` with `owner_id` and no `owner_uuid` gets no `owner_uuid` entry, and the admin's Effective access does not list one. A Resource whose model this app cannot load (no such class, or its schema cannot be read) keeps every variant.

`FiltersResponseAttributes` still treats a key that is a variant the model does not have — a `company_uuid` your serializer computes — as the field it is a variant of: hidden, masked or shown as `company_id` is. `user.field_permissions(:Customer, :company_uuid)` and `permissions_hash_for(:Customer)[:fields][:company_uuid]` answer `nil` for such a name; give the model a `company_uuid` reader (or declare it) if your code reads the entry.

### Custom Variants

Add your own mappings in the initializer:

```ruby
config.field_variant_mappings = {
  /_id\z/    => ->(name) { "#{name.sub(/_id\z/, '')}_uuid" },
  /_cents\z/ => ->(name) { name.sub(/_cents\z/, '') },
  # Add your own:
  /_code\z/  => ->(name) { "#{name.sub(/_code\z/, '')}_label" }
}
```

## Extra Virtual Fields

Some models have computed or virtual attributes that aren't database columns. You can register these for permission tracking:

```ruby
class Customer < ApplicationRecord
  def self.extra_fields_for_permissions
    %w[full_address contact_count total_revenue]
  end
end
```

A virtual field is configured like a column: give it a `ResourceField` row (Hidden, Masked, Read-only or Editable) in the admin's Fields tab or in code. The row is what `PermitsAttributes` and `FiltersResponseAttributes` enforce; record rules never use virtual fields, because rules are SQL.

### A virtual field nobody configured

What a declared virtual field gets when a resource has no row for it is set by `config.extra_fields_default_access`:

| Value | A declared virtual field with no row |
|-------|--------------------------------------|
| `:grant` (default) | Gets an implicit entry that follows the resource: `read_access` when the user's merged resource grants read, `edit_access` when it grants edit, never masked. (Before 0.14 the entry was read + edit for everyone the resource was readable for, so a read-only user could write a declared virtual field.) |
| `:unconfigured` | Gets no entry. It follows `config.unconfigured_field_strategy` on the read path, like a column nobody configured, and is never editable. With the default `:block` it is hidden until an admin gives it a level. |

```ruby
PermissionForge.configure do |config|
  config.extra_fields_default_access = :unconfigured
end
```

Any value other than `:grant` behaves as `:unconfigured`.

Under `:grant`, a row always wins over the implicit entry: an extra field never unmasks or grants edit on a field an admin configured. This holds across Permission Sets too. The implicit entry is added once, after all of a person's granting sets are merged, and only for a virtual field that none of those sets has a row for. (Before 0.13.0 it was added per set, so a row in a newer set lost to an older set's implicit read + edit.)

Only an active row counts. A row that is turned off (`is_active: false`) is skipped when permissions are built, so the field is treated as if it had no row: under `:grant` it gets the implicit entry again (readable and editable wherever the resource is). To take access away, set the row to Hidden and leave it turned on.

A muting set that revokes the resource's read hides the implicit entries too.

The admin helps with that under `:grant`:

- *Add a resource* creates rows for virtual fields at the preset's level, so *Read-only* really is read-only.
- The Fields tab lists every unconfigured virtual field as **Not configured · Editable by default**, and *Sync fields with model* adds them at a level you choose. A row that is turned off shows **Turned off · Editable by default**.
- The privacy audit on the home page, `GdprFieldAuditor` (`:implicit_virtual_grant`) and `rake permission_forge:audit` (`implicit_virtual_personal_data`) report virtual fields that look like personal data and are still on the implicit grant, including fields whose only row is turned off.

`ResourceFieldGenerator` and `Resource.grant_full_access!` create rows for virtual fields only under `:unconfigured`. Under `:grant` they leave them to the implicit entry, as before.

### When `extra_fields_for_permissions` raises

The declared names are read in one place, `PermissionForge::VirtualFields`:

- Building a person's permissions (`PermissionForge::VirtualFields.extra_names`) does not rescue. The error reaches the caller, so a broken method never changes anyone's permissions silently.
- The admin, the audits and the wrapping of virtual readers log a warning that names the model and the error, and carry on as if the model declared no virtual fields. For reader wrapping, the log also says that the model's virtual readers are not masked.

### Discovered virtual fields

With `config.virtual_field_discovery = true` the admin also lists virtual fields the model has but does not declare:

- attribute-API attributes with no column (`attribute :nickname, :string`)
- store accessors, by reader name (`store_accessor :settings, :theme`, including `prefix: true` and `suffix: true`; accessors with a custom prefix or suffix are not found, so declare those)

Discovered names are suggestions for the admin. They never get the implicit entry, in either mode: until someone gives them a level they follow `unconfigured_field_strategy`.

Nested-attribute names (`contacts_attributes`) are not listed. `PermitsAttributes` filters a nested payload by the nested model's own resource (see below), and a row on the parent would not mean what its level says.

### Enforcement on the model

By default a virtual field's level is enforced where your code filters: `PermitsAttributes` for params and `FiltersResponseAttributes` for response hashes. Code that calls the reader on the record (`customer.full_address`, a serializer, a view) gets the real value. To enforce the level there too, see `config.mask_virtual_attributes` in [masked-attributes.md](masked-attributes.md#virtual-readers).

## Nested attributes

`PermitsAttributes` reads every key of the params in one of two ways:

- **A field.** Kept when the user may edit that field on the resource, whatever its value. A Hash or an Array is a value like any other (a json column), never a payload to look into, so a key the user may not edit is dropped whatever it holds. A plain nested array such as `contacts: [{ ... }]` is such a field.
- **A nested payload:** `<association>_attributes`, for an association the model declares with `accepts_nested_attributes_for`. Any other `*_attributes` key is a field.

A nested payload is filtered record by record against the **association model's own** resource (with its STI ancestors'), not the parent's:

```ruby
class Customer < ApplicationRecord
  has_many :contacts
  accepts_nested_attributes_for :contacts
end

params = {
  name: 'Acme Corp',
  contacts_attributes: [
    { id: 7, name: 'Alice', email: 'alice@acme.com' },
    { name: 'Bob', phone: '555-1234' }
  ]
}

# The user may edit Customer#name, Contact#name and Contact#phone (not Contact#email),
# and contact 7 is a row the Contact rules let them reach:
# { name: 'Acme Corp', contacts_attributes: [{ id: 7, name: 'Alice' }, { name: 'Bob', phone: '555-1234' }] }
```

- **Shapes.** An Array of records, Rails' index Hash (`{ '0' => {...}, '1' => {...} }`), or one Hash for a `has_one` / `belongs_to`. A collection Hash with an `id` key is one record, as Rails reads it. An element that is not a record is dropped.
- **No entry for the child model** in the user's permissions: the whole payload is dropped. `config.nested_attributes_parent_fallback = true` filters it against the parent resource's fields instead (default `false`; not recommended, because a key editable on the parent then admits the same key on a child the user was never granted, and `rake permission_forge:audit` reports it as `nested_parent_fallback`, medium). A payload for a polymorphic association, or one whose model does not load, is dropped.
- **`id`.** When the child model includes `PermissionScopedFindable`, a record's `id` is kept only when it names a row inside `Child.permission_scoped` for the current user (a child with no rules for the user, or with `view_all`, reaches every row). Otherwise the **whole record** is dropped — dropping only the id would turn an update into a create — and so is a record whose id names no row. This costs one query per payload: a payload nested inside each of 20 child records (depth 2) costs one query per child record, plus one for the children. A child model without the concern is left to Rails, which refuses (`RecordNotFound`) the id of a row that belongs to another parent but loads any row of the same parent. The check also applies under the parent fallback.
- **A blank id** (`''` or `nil`) is a new record, as Rails reads it: nothing is checked.
- **A record with both `'id'` and `:id`** (a plain Hash): kept with one of them when both name the same id, dropped when they differ.
- **`_destroy`.** A nested record keeps `_destroy` when the signed-in user may delete the model the payload is filtered for — the `delete_access` of the entry that model answers to (its own, or its nearest STI base's when it has none; the parent's under `nested_attributes_parent_fallback`). Otherwise `_destroy` is dropped and reported as `contacts_attributes.*._destroy`, and the record stays (an update). A record whose `id` the child's rules deny is dropped whole, `_destroy` or not. At the top level `_destroy` is not a field and is dropped.

The dropped paths are published as the `params.filtered` [audit event](audit-log.md) when it is stored or listened to (`contacts_attributes.*.email`, `contacts_attributes.*` for a record dropped whole), never their values.

## Unconfigured Field Strategy (v0.5.0+)

`FiltersResponseAttributes` looks the resource name up along the model's single-table-inheritance chain: `resource_name: 'VipCustomer'` uses the user's `VipCustomer` entry and their `Customer` entry together, the strictest of them deciding each field (see [masked-attributes.md](masked-attributes.md#single-table-inheritance)). A name that is not a model class is looked up as given.

When `FiltersResponseAttributes` encounters a field that has no `ResourceField` record (unconfigured), it consults `config.unconfigured_field_strategy`:

| Strategy | Behavior | Use case |
|----------|----------|----------|
| `:block` | Exclude field from response entirely (default) | Secure default — deny by default |
| `:mask_all` | Apply full masking (`********`) | Strict security — mask anything unknown |
| `:warn` | Pass through + log warning | Catch missing field configs during migration |
| `:pass_through` | Field passes through unmasked | Legacy behavior, NOT recommended for production |

```ruby
PermissionForge.configure do |config|
  config.unconfigured_field_strategy = :block  # default (secure)
end
```

> **Security Note:** The default changed from `:warn` to `:block`. New model columns added after initial setup are now excluded from API responses until a `ResourceField` record is explicitly created. This prevents accidental data exposure. Set `:warn` or `:pass_through` explicitly if you need the legacy behavior. Unknown strategy values also fall back to `:block` — never pass-through.

Related fail-closed behavior (v0.10.0+):

- An authenticated user with **no configured access to the resource at all** no longer receives the raw attributes — every field is routed through `unconfigured_field_strategy`.
- `user.masked_field?` reports unconfigured fields as **masked** under `:block` / `:mask_all` instead of defaulting to "not masked".
- The no-current-user case is controlled separately by `config.response_filter_nil_user_strategy`: `:bypass` (default) returns attributes unfiltered for system/console contexts, `:block` returns `{}`. Model masking has its own setting, `config.masked_attributes_nil_user_strategy` (`:bypass` default / `:hide`; the user model is exempt).

## Audit Logging Hook (v0.5.0+)

Call your own code for each field-level decision the gem makes (response filtering and `MaskedAttributes` reads; not `pluck` or raw SQL):

```ruby
PermissionForge.configure do |config|
  config.on_field_filtered = lambda { |resource_name:, field_name:, action:, user:|
    AuditLog.create!(
      resource: resource_name,
      field: field_name,
      action: action,      # :hidden, :masked, :passed — plus :unconfigured / :bypassed from MaskedAttributes
      user_id: user&.id,
      timestamp: Time.current
    )
  }
end
```

The hook is called for each configured field during `FiltersResponseAttributes.call`, and (since v0.9.0) for every attribute decision made by the `MaskedAttributes` concern — those model-level reads can additionally report `:unconfigured` and `:bypassed` actions. The hook is a subscriber of the `field.access` [audit event](audit-log.md), called once per field decision, in the same order with the same arguments: as the decision is made when it is the only listener and `field_read` is not stored (as before), otherwise when the read returns. If it raises, the error follows `config.audit_hook_failure_strategy`: by default (`:report`) it is logged and handed to `Rails.error` and filtering is not interrupted; under `:raise` it propagates out of the read. To *store* who could read which fields instead of calling your own code, add `:field_read` to `config.audit_runtime_events` (one `field.access` event per record read, with field names, never values).

## Tips

1. **Cache invalidation is automatic for ActiveRecord changes** — saving a `ResourceField` (or any permission record) invalidates the affected users' cached hashes, and the hash rebuilds automatically on the next read (read-through, v0.10.0+). Call `user.invalidate_permissions` or `user.regenerate_permissions` manually only after changes that bypass AR callbacks (`update_all`, `insert_all`, raw SQL) — and note that such changes write no audit event either.

2. **Use `grant_all: true` for admin sets** — saves time when you want full access. Since 0.15.0 it applies no mask, also with `gdpr_defaults: true` (before, GDPR-sensitive fields were still masked). Run `rake permission_forge:audit_masks` afterwards and mask the personal-data fields the set should not read in the clear; or generate without `grant_all` (sensitive fields start masked, the rest without access) and open what is needed.

3. **Check the ignored_fields config** — fields like `id`, `uuid` and `password` are excluded by default (Rails' timestamps get a row, at most read-only, instead). Customize the list if needed.

4. **Field names are case-sensitive** — `Name` and `name` are different fields to the engine. Always use the exact database column name. (On a case-insensitive collation, MySQL's default, the two cannot both be saved on one resource: the second is a validation error.)

5. **Run the GDPR audit regularly** — `bundle exec rake permission_forge:audit_masks` detects both unmasked fields and unmapped model columns matching PII patterns.
