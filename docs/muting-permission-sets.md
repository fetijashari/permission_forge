# Muting Permission Sets

## Overview

Muting permission sets **subtract** permissions instead of granting them. When a user is assigned both granting and muting permission sets, the granting sets are merged first (most-permissive-wins), then muting sets revoke specific permissions.

This is inspired by Salesforce's Muting Permission Sets feature (released 2020).

## When to Use

- **Temporary restrictions** — Mute access during an investigation without removing users from their team
- **Compliance carve-outs** — "Everyone in Finance can see all reports *except* executive compensation"
- **Onboarding ramp-up** — New hires start with a muting set that gets removed as they complete training
- **Contractor limits** — Same group as employees, but with a muting set that blocks sensitive resources
- **Junior access control** — Broad team access minus delete/export capabilities

## Creating a Muting Permission Set

### Via Admin UI

1. Permission Sets → **New Permission Set**, choose **Removes access**
2. Add resources (start from *Hide sensitive fields*, *Block all changes* or *Leave everything unchanged*)
3. The editor is in muting mode (orange banner): CRUD cells read **Muted / Unchanged**, fields offer **Unchanged / Force mask / Hide**, actions **Block**
4. Assign the muting set to people — their **Effective access** tab shows what it takes away and why

An existing set can be switched between granting and muting under *Technical details*, behind a warning that every setting inverts.

### Via API

```bash fragment
POST /api/permission_sets
{
  "permission_set": {
    "name": "Junior Restriction",
    "is_muting": true,
    "is_active": true
  }
}
```

### Via Code

```ruby run
muting_set = PermissionForge::PermissionSet.create!(
  name: 'Junior Restriction',
  is_muting: true,
  is_active: true
)

# Define what to revoke — true means "revoke this permission"
resource = PermissionForge::Resource.create!(
  permission_set: muting_set,
  name: 'Customer',
  delete_access: true,  # Revokes delete
  view_all: true        # Revokes view_all
)

# Revoke field access
PermissionForge::ResourceField.create!(
  resource: resource,
  name: 'salary',
  read_access: true,    # Revokes read on salary
  mask_access: true     # Forces masking on salary
)

# Revoke actions
PermissionForge::ResourceAction.create!(
  resource: resource,
  name: 'export',
  is_permitted: true    # Revokes export action
)
```

## How It Works

### Merge Order

1. **Partition** — Permission sets are split into granting (`is_muting: false`) and muting (`is_muting: true`)
2. **Grant phase** — Granting sets are merged using existing most-permissive-wins logic
3. **Mute phase** — Muting sets subtract from the merged result

Sets are merged in deterministic order (`created_at`, then `id`), so tie-breakers like "first `mask_strategy` wins" are stable across requests and database adapters.

### What Gets Muted

| Permission Type | Muting Behavior |
|----------------|-----------------|
| Resource CRUD (`read_access`, `create_access`, etc.) | Set to `false` if muting resource has it as `true` |
| Every field of the resource, when the muting resource has `read_access: true` | `read_access` and `edit_access` set to `false` on every field entry of the resource — configured fields, their variants and the implicit entries of declared virtual fields (see below) |
| `view_all` / `modify_all` | Set to `false` if muting resource has it as `true` |
| Field `read_access` / `edit_access` | `read_access` set to `false` if the muting field has it as `true`; `edit_access` set to `false` if the muting field has `read_access` **or** `edit_access` as `true` (a field nobody may read is not one they may write) |
| Field variants (`_uuid`, `_cents` base name, etc.) | Muted alongside the base field — muting `user_id` also revokes `user_uuid`; muting `price_cents` also revokes `price` (follows the configured `field_variant_mappings`) |
| Field `mask_access` | Set to `true` (force masking) if muting field has `mask_access: true` |
| Action `is_permitted` | Set to `false` if muting action has `is_permitted: true` |
| Row-level rules | **Not affected** — muting sets do NOT add rules |

A muting set only acts on a resource the user's granting sets give them: a muting resource for a model no granting set has does nothing.

### Muting a resource's read, muting its edit

The resource's CRUD flags and its fields are separate. In a **granting** set, field rows decide field access: the resource's `read_access` does not hide fields by itself, and nothing guards the getters or `find_by` with the CRUD flags. They are enforced where your code calls `can_read?` / `can_edit?` (and the other `can_*?`) or uses [ControllerActionGuard](controller-actions.md).

A **muting** set is stricter for read:

- **Muting the resource's read hides every field** of that resource: the getters return the hidden value, `as_json` and `FiltersResponseAttributes` leave the fields out, and `PermitsAttributes` drops them. This also blocks those fields **on create** through `PermitsAttributes`. A "submit but not see" pattern needs a muting set that does not mute read.
- **Muting the resource's edit mutes the flag only.** `can_edit?` answers false, and the fields keep what their rows say, so a create through `PermitsAttributes` still goes through. To make fields read-only, mute their `edit_access` field by field.

**Single-table inheritance.** A subclass answers to its own resource entry and to each ancestor's (see [row-level-rules.md](row-level-rules.md#single-table-inheritance)). A muting resource row naming a model reaches the entry of every STI subclass of that model the person holds an entry for — its CRUD flags, View All / Modify All, actions and field rows — so muting the base revokes `can_*?` and the controller guard on the subclass too, and the subclass entry lists the muting set among its `source_permission_sets`. A muting row naming a subclass reaches that subclass alone. (A subclass with no resource row of its own is its base.) Field reads were already composed along the chain: when any of the entries a class answers to does not grant read, every field the chain configures is hidden, including fields only the subclass's entry configures.

### What Does NOT Get Muted

- **Permissions not defined in the muting set** — Only explicitly targeted permissions are revoked (the cascades: a muted resource read hides the resource's fields; a muted field read mutes its edit; a muting row naming an STI base reaches the subclass entries)
- **Rules** — Muting sets do not add row-level rules
- **Resources not in the muting set** — Other resources remain unaffected

## Dependency Validation

For granting sets, `ValidatesDependency` enforces rules like "delete requires read" and "modify_all requires view_all". For muting sets, these validations are **skipped** because the semantics are inverted — `delete_access: true` means "revoke delete", not "grant delete".

## Example: Group with Muting Carve-Out

```ruby fragment
group = PermissionForge::PermissionSetGroup.create!(name: 'Sales Team')

# Broad access for the team
granting = PermissionForge::PermissionSet.create!(
  name: 'Sales CRM Access',
  permission_set_group: group,
  is_active: true
)
PermissionForge::Resource.create!(
  permission_set: granting, name: 'Customer',
  read_access: true, create_access: true, edit_access: true, delete_access: true
)

# Junior restriction (muting)
muting = PermissionForge::PermissionSet.create!(
  name: 'Junior Lock',
  permission_set_group: group,
  is_muting: true,
  is_active: true
)
PermissionForge::Resource.create!(
  permission_set: muting, name: 'Customer',
  delete_access: true  # Only revoke delete
)

# Assign: senior gets granting only, junior gets both
PermissionForge::PermissionSetUser.create!(user: senior, permission_set: granting)

PermissionForge::PermissionSetUser.create!(user: junior, permission_set: granting)
PermissionForge::PermissionSetUser.create!(user: junior, permission_set: muting)

# No manual regeneration needed — assignment changes invalidate the cached
# hash, which is rebuilt read-through on the next permission check.

senior.can_delete?(:Customer) # => true
junior.can_delete?(:Customer) # => false
junior.can_read?(:Customer)   # => true (not muted)
```

## Cache Format

Muting sets are included in `source_permission_sets` with an `is_muting` flag:

```ruby fragment
{
  permissions: {
    resources: {
      Customer: {
        source_permission_sets: [
          { uuid: "grant-uuid", name: "Sales CRM", is_muting: false, ... },
          { uuid: "mute-uuid", name: "Junior Lock", is_muting: true, ... }
        ]
      }
    }
  }
}
```

## Scopes

```ruby run
PermissionForge::PermissionSet.muting    # Only muting sets
PermissionForge::PermissionSet.granting  # Only granting sets
```

## Model Methods

```ruby fragment
permission_set.muting?   # true if is_muting
permission_set.granting? # true if not is_muting
```
