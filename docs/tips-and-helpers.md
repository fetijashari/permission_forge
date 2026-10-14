# Tips, Helpers, and Common Patterns

Useful patterns, debugging techniques, and things to watch out for when using PermissionForge.

## Debugging Permissions

### Inspect the Cached Hash

The fastest way to debug is to look at what's actually cached:

```ruby
pp user.permissions_hash   # read-through: a cache miss rebuilds it
```

This shows you the exact data structure that all permission checks use. If something is wrong, the answer is usually in this hash.

### Check if Cache is Populated

```ruby
# Read the raw entry (permission_cache_key is tenant-aware: "v2:user_42",
# "v2:tenant_1_user_42"; the store adds cache_key_prefix in front)
PermissionForge.cache.read(user.permission_cache_key)
# => nil means nothing is cached right now — not an error state:
#    permissions_hash is read-through, so the next permission check
#    rebuilds the hash automatically
```

For a user who holds conditional Permission Sets this entry is the **base**: the unconditional sets plus a `:conditional_sets` key that lists them and their conditions. The hash a request actually uses (base plus the conditional sets that pass for that request) is `user.permissions_hash`; see [Activation Conditions](activation-conditions.md).

### Verify Permission Set Assignment

```ruby
# Is the user assigned to any permission sets?
user.permission_sets.count
# => 0 means no permissions at all!

# Is the permission set active?
user.permission_sets.map { |ps| [ps.name, ps.is_active] }
# => [["Sales", true], ["Archive", false]]
```

### Check Resource Configuration

```ruby
pset = user.permission_sets.first
pset.resources.map { |r| [r.name, r.is_active, r.read_access] }
# => [["Customer", true, true], ["Article", true, false]]
```

## Common Patterns

### Pattern: Admin Bypass

For admin users who should skip all permission checks:

```ruby
class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser

  def can_read?(resource)
    return true if admin?
    super
  end

  def can_create?(resource)
    return true if admin?
    super
  end

  # ... same for can_edit? and can_delete?
end
```

### Pattern: Permission-Based Serialization

Filter your API responses based on field-level read access. (Since v0.9.0, models with `MaskedAttributes` auto-applied already filter and mask `attributes` / `as_json` output — this manual pattern is mainly for when auto-apply is disabled.)

```ruby
def serialize(record, user)
  entry = user.permissions_hash_for(record.class.name.to_sym)
  fields = entry&.dig(:fields) || {}

  record.attributes.select do |key, _|
    field_perm = fields[key.to_sym]
    field_perm && field_perm[:read_access]
  end
end
```

### Pattern: Bulk Permission Regeneration

Changes made through ActiveRecord (saving a permission set, resource, field, action, rule, or assignment) invalidate affected users' caches automatically (v0.10.0+) — the hash rebuilds lazily on each user's next read. You only need a manual pass when you bulk-modify permission data in ways that skip callbacks (`update_all`, `insert_all`, raw SQL):

```ruby
pset = PermissionForge::PermissionSet.find_by(uuid: uuid)
pset.permission_set_users.includes(:user).find_each do |psu|
  psu.user&.invalidate_permissions
end
```

> **Tip:** Prefer `invalidate_permissions` over `regenerate_permissions` here — it only deletes cache keys (the base entry and every per-context variant), and each user rebuilds on their next permission check.

### Pattern: Seed Permissions

Create a rake task or seed file for your default permission sets. `is_editable = false` locks the set in the admin and the admin API. Locking freezes what the set gives; changes to who holds it pass only when they narrow access: holders of a granting set can still be removed and their end dates shortened (for a Muting Permission Set it is the other way round: holders can be added and kept longer).

```ruby
# db/seeds/permissions.rb
admin_pset = PermissionForge::PermissionSet.find_or_create_by!(name: 'Admin') do |ps|
  ps.is_active = true
  ps.is_editable = false
end

%w[Customer Article Supplier Project].each do |model_name|
  PermissionForge::Resource.grant_full_access!(
    permission_set: admin_pset,
    resource_name: model_name
  )
end
```

### Pattern: Testing with Permissions

Create a shared helper module for your tests:

```ruby
# test/support/permission_helpers.rb
module PermissionHelpers
  def grant_permissions(user, resource_name, read: true, create: false, edit: false, delete: false)
    ps = PermissionForge::PermissionSet.create!(uuid: SecureRandom.uuid, name: "Test #{resource_name}", is_active: true)
    resource = PermissionForge::Resource.create!(
      uuid: SecureRandom.uuid,
      permission_set: ps,
      name: resource_name,
      read_access: read,
      create_access: create,
      edit_access: edit,
      delete_access: delete,
      is_active: true
    )
    PermissionForge::PermissionSetUser.create!(uuid: SecureRandom.uuid, user: user, permission_set: ps)

    # Auto-generate fields with full access for testing
    model_class = resource_name.constantize
    (model_class.column_names - %w[id created_at updated_at]).each do |col|
      PermissionForge::ResourceField.create!(
        uuid: SecureRandom.uuid,
        resource: resource,
        name: col,
        label: col.humanize,
        read_access: true,
        edit_access: true
      )
    end

    resource # no refresh call needed: the saves above invalidated the user's cached permissions
  end
end

# Usage in tests:
class CustomersControllerTest < ActionDispatch::IntegrationTest
  include PermissionHelpers

  setup do
    @user = User.create!(name: 'Test User', email: 'test@example.com') # or a fixture
    grant_permissions(@user, 'Customer', read: true, create: true, edit: true)
  end

  test 'allows creating a customer' do
    # ...
  end
end
```

## Things to Watch Out For

### 1. Permissions Are Cached — Know How the Cache Refreshes

Permission checks read a cached hash. Since v0.10.0 the cache manages itself for the common cases:

- Saving any permission record (permission set, resource, field, action, rule, assignment) through ActiveRecord **invalidates** the affected users' cached hashes automatically.
- Reads are **read-through**: a cache miss (invalidation, TTL expiry, eviction) rebuilds the hash on the next `permissions_hash` access — it no longer silently returns `{}`.

```ruby
resource.update!(read_access: true)
user.can_read?('Customer')  # => true — the update invalidated the cache,
                            #    and the check rebuilt it read-through
```

You still must invalidate manually when a change **bypasses ActiveRecord callbacks**:

```ruby
# BAD — update_all skips callbacks, so caches are NOT invalidated
PermissionForge::Resource.where(name: 'Customer').update_all(read_access: true)
user.can_read?('Customer')  # May still return the old value!

# GOOD — invalidate (or regenerate) affected users afterwards
PermissionForge::Resource.where(name: 'Customer').update_all(read_access: true)
user.invalidate_permissions   # cheap: next read rebuilds
user.can_read?('Customer')    # Now returns true
```

### 2. Resource Names Are Case-Sensitive

The resource `name` must exactly match your Ruby class name:

```ruby
# GOOD
PermissionForge::Resource.create!(name: 'Customer', ...)
user.can_read?('Customer')  # Works

# BAD
PermissionForge::Resource.create!(name: 'customer', ...)  # refused: "must be a valid model class name"
user.can_read?('customer')  # false: names are case-sensitive, the entry is :Customer
```

### 3. The Class-Level `find_by` / `find_by!` Are Overridden, Not `where`

`PermissionScopedFindable` overrides the class methods `find_by` and `find_by!` (v0.10.0+). With the default `auto_query_scoping = :off`, everything else is NOT scoped: bare collection queries (`where`, `all`, `find` by primary key, scopes, association traversal), and `find_by` called on a relation or an association:

```ruby
Customer.find_by(uuid: 'abc')   # Rules applied — nil when the record is missing,
                                # NotAuthorizedError only when it exists but a rule denies it
Customer.find_by!(uuid: 'abc')  # Same, but raises ActiveRecord::RecordNotFound when missing
Customer.where(name: 'Acme')    # NO permission rules — returns all matches
Customer.all                    # NO permission rules
Customer.where(active: true).find_by(uuid: 'abc')  # NO permission rules
supplier.customers.find_by(uuid: 'abc')            # NO permission rules
Customer.unscoped.find_by(uuid: 'abc')             # NO permission rules
Customer.find_sole_by(uuid: 'abc')                 # NO permission rules
```

For collections, start from `Customer.permission_scoped` (v0.10.0+) — it returns a rule-constrained relation that carries the rules through any further chaining (`.where`, `.order`, `.first`, `.count`).

With `auto_query_scoping = :filter_only` the scope is decided when the relation is built: a relation built with no current user (a constant, a `before_action` that runs before authentication) stays unscoped when it loads later. Build relations in the request, after the user is known ([query-scoping.md](query-scoping.md)).

### 4. No Current User = No Rules (by Default)

When `PermissionForge.current_user` returns nil (e.g., in background jobs, seeds, console), row-level rules are bypassed by default:

```ruby
Current.user = nil
Customer.find_by(uuid: 'abc')  # Returns the record, no rules applied
```

This is intentional — system-level code shouldn't be blocked by user permissions. It's also configurable via `config.nil_user_strategy`: `:bypass` (default), `:deny` (returns nil), or `:raise` (raises `NotAuthorizedError`). The read-path equivalent for `FiltersResponseAttributes` is `config.response_filter_nil_user_strategy` (`:bypass` default / `:block`). Model masking follows `config.masked_attributes_nil_user_strategy` (`:bypass` default / `:hide`).

### 5. Multiple Permission Sets Merge

If a user is assigned to multiple permission sets, their permissions are **merged** (OR logic):

- Permission Set A: Customer `read_access: true, edit_access: false`
- Permission Set B: Customer `read_access: false, edit_access: true`
- **Result:** Customer `read_access: true, edit_access: true`

The first `true` wins for each flag. This means you can't use a **granting** permission set to **remove** access that another set grants. To subtract access, use a muting permission set (`is_muting: true`) — muting sets are applied after the granting merge and can revoke resource CRUD, field access, and actions. See [Muting Permission Sets](muting-permission-sets.md).

**Row-level rules work the other way: they intersect.** The rules of every granting set apply together, so giving someone a second set that has a rule on `Customer` narrows the customers they see — it never widens them. Only `view_all` / `modify_all` (from any granting set) lifts the rules on a resource.

### 6. Dependency Validations

PermissionForge enforces logical dependencies between permission flags. If you try to enable a flag without its prerequisite, validation will fail:

```ruby
# BAD — will raise ActiveRecord::RecordInvalid
PermissionForge::Resource.create!(
  name: 'Customer', read_access: false, edit_access: true  # edit requires read!
)

# GOOD — enable read first
PermissionForge::Resource.create!(
  name: 'Customer', read_access: true, edit_access: true
)
```

**Rules:**
- `edit_access` requires `read_access` (Resource + ResourceField)
- `delete_access` requires `read_access` (Resource)
- `modify_all` requires `view_all` (Resource)
- `mask_access` requires `read_access` (ResourceField)

When disabling `read_access`, also disable dependent flags in the same update:
```ruby
resource.update!(read_access: false, edit_access: false, delete_access: false)
```

### 7. Field Variant Gotcha

If your model has `company_id`, PermissionForge auto-creates a permission entry for `company_uuid`. But if you create a field permission for `company_uuid` directly (not `company_id`), the variant won't be created the other way.

**Rule:** Always create field permissions using the actual database column name (`company_id`), and the variants will be auto-generated.

If you do create both, the row merged first wins the mask strategy of the variant name (sets in `created_at` order, rows within a set in id order; the first read-granting row of a name sets the strategy). So an explicit `company_uuid` row created after `company_id` in the same set cannot change the strategy the `company_id` variant brought; its read, edit and unmask still count.

## Useful Helpers

### Check All Permissions at Once

```ruby
def permission_summary(user)
  hash = user.permissions_hash
  resources = hash.dig(:permissions, :resources) || {}

  resources.map do |name, data|
    perms = data[:permissions]
    fields_count = data[:fields]&.size || 0
    rules_count = data[:permission_set_rules]&.size || 0

    {
      resource: name,
      read: perms[:read_access],
      create: perms[:create_access],
      edit: perms[:edit_access],
      delete: perms[:delete_access],
      view_all: perms[:view_all],
      modify_all: perms[:modify_all],
      fields: fields_count,
      rules: rules_count
    }
  end
end

# Usage:
pp permission_summary(user)
# [
#   { resource: :Customer, read: true, create: true, edit: false, delete: false, fields: 12, rules: 1 },
#   { resource: :Article, read: true, create: false, edit: false, delete: false, fields: 8, rules: 0 }
# ]
```

### Clear All Cached Permissions

```bash
ACTOR="ops: TCK-12" REASON="revoke everything cached" bin/rails permission_forge:cache:clear
```

Every user's cached permissions go, in every tenant, and each user rebuilds on their next permission check (one rebuild per user). The run is recorded as `cache.cleared`. `PermissionForge.cache.clear` is the low-level alternative: no audit event, it does not retire memos already held by user instances, and on Solid Cache and Memcached it removes nothing (see [Cache Consistency](configuration.md#cache-consistency)).

### Find Users Without Permissions

```ruby
User.where.missing(:permission_set_users)
# Returns users who aren't assigned to any permission set (whatever the table prefix)
```
