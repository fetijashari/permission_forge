# Permission Set Groups

Permission Set Groups are an optional way to organize multiple permission sets together. Think of them as folders for your permission sets.

## When to Use Groups

Groups are useful when you have many permission sets and want to:
- Organize them by department (Sales, Finance, Operations)
- Clone a whole family of related sets in one operation (group clone is deep — sets, resources, fields, actions, rules; no members or assignments are copied)
- Track which users belong to a team via group membership

> **Note:** Groups are purely organizational. Group membership does NOT grant the group's permission sets — permissions come only from direct `PermissionSetUser` assignments. Likewise, deactivating a group does not deactivate its sets (see the note below).

## Creating a Group

```ruby
sales_group = PermissionForge::PermissionSetGroup.create!(
  name: 'Sales Department',
  description: 'All permission sets for sales team members',
  is_active: true
)
```

## Adding Permission Sets to a Group

```ruby
# When creating a permission set, assign it to a group:
pset = PermissionForge::PermissionSet.create!(
  name: 'Customer Management',
  permission_set_group: sales_group,
  is_active: true
)

# Or update an existing permission set:
existing_pset.update!(permission_set_group: sales_group)
```

## Assigning Users to Groups

```ruby
PermissionForge::PermissionSetGroupUser.create!(
  permission_set_group: sales_group,
  user: user
)
```

> **Note:** Assigning a user to a group is for organizational purposes. The actual permissions still come from the individual permission sets assigned via `PermissionSetUser`.

> **Note:** A user can only be assigned to a group once — a repeat assignment fails validation (`ActiveRecord::RecordInvalid`; the admin API returns 422) instead of raising a database uniqueness error.

## Listing Group Members

```ruby
sales_group.users
# => [#<User id: 1>, #<User id: 2>, ...]

sales_group.permission_sets
# => [#<PermissionForge::PermissionSet name: "Customer Management">, ...]
```

## Active/Inactive Groups

```ruby
# Only active groups
PermissionForge::PermissionSetGroup.active
# => groups where is_active = true

# Deactivate a group
sales_group.update!(is_active: false)
```

> **Note:** Deactivating a group does NOT automatically deactivate its permission sets. You need to deactivate each permission set individually if needed.

## Tips

1. Groups are optional — you don't need to use them. Permission sets work fine on their own.
2. A permission set can only belong to one group (or no group).
3. Deleting a group sets `permission_set_group_id` to NULL on its permission sets (they aren't deleted). Each set is detached with a normal save, so each change is an audit event.
4. **Locked groups.** In the admin and the admin API, a group with `is_editable: false` keeps its name, its members and its list of sets: members can be neither added nor removed (membership grants no access, so there is nothing to narrow), a set cannot be moved into or out of it, and a set in it cannot be deleted. Duplicating or cloning a set that is in a locked group makes an editable copy outside the group. A locked group does not lock its sets' content. The lock is enforced by the admin and the API, not by the models: code that writes the records directly is not refused.
