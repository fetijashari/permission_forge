# Table Name Prefix

PermissionForge creates 9 database tables: the 8 permission tables and the audit log. By default, all tables are prefixed with `permission_forge_` to avoid collisions with your application's existing tables.

## Default Table Names

| Model | Table Name |
|-------|-----------|
| PermissionSet | `permission_forge_permission_sets` |
| PermissionSetUser | `permission_forge_permission_set_users` |
| PermissionSetGroup | `permission_forge_permission_set_groups` |
| PermissionSetGroupUser | `permission_forge_permission_set_group_users` |
| Resource | `permission_forge_resources` |
| ResourceField | `permission_forge_resource_fields` |
| ResourceAction | `permission_forge_resource_actions` |
| PermissionSetRule | `permission_forge_permission_set_rules` |
| AuditEvent | `permission_forge_audit_events` |

## Choosing a Prefix During Installation

The install generator accepts a `--table-prefix` option:

```bash fragment
# Default — full prefix (recommended for new apps)
rails generate permission_forge:install

# Shorter prefix
rails generate permission_forge:install --table-prefix=pf_

# No prefix (for existing apps with established tables)
rails generate permission_forge:install --table-prefix=''
```

The generator creates:
1. **Migration** — `create_table` statements use your chosen prefix
2. **Initializer** — `config.table_name_prefix` is set to match

The upgrade generator (`rails generate permission_forge:upgrade`, which adds schema hardening from v0.10.0 — see the [migration guide](migration-guide.md)) defaults to your configured `config.table_name_prefix` (since 0.12.1), and accepts the same `--table-prefix` option to override it.

## Changing the Prefix After Installation

Edit your initializer, then restart every process (web, jobs, consoles):

```ruby fragment
# config/initializers/permission_forge.rb
PermissionForge.configure do |config|
  config.table_name_prefix = 'pf_'  # or '' for no prefix
end
```

If you're changing the prefix on an existing database, you'll need to rename the tables:

```ruby fragment
# db/migrate/YYYYMMDDHHMMSS_rename_permission_forge_tables.rb
class RenamePermissionForgeTables < ActiveRecord::Migration[7.2]
  def change
    rename_table :permission_forge_permission_sets, :pf_permission_sets
    rename_table :permission_forge_resources, :pf_resources
    rename_table :permission_forge_resource_fields, :pf_resource_fields
    rename_table :permission_forge_resource_actions, :pf_resource_actions
    rename_table :permission_forge_permission_set_rules, :pf_permission_set_rules
    rename_table :permission_forge_permission_set_users, :pf_permission_set_users
    rename_table :permission_forge_permission_set_groups, :pf_permission_set_groups
    rename_table :permission_forge_permission_set_group_users, :pf_permission_set_group_users
    rename_table :permission_forge_audit_events, :pf_audit_events
  end
end
```

Only table names carry the prefix. Foreign-key columns are always `permission_set_id`, `resource_id` and `permission_set_group_id`, whatever the prefix, so renaming the tables is all a prefix change needs.

## How It Works

All 9 models use dynamic `def self.table_name` methods instead of static `self.table_name =` assignments:

```ruby fragment
# app/models/permission_forge/permission_set.rb
module PermissionForge
  class PermissionSet < ActiveRecord::Base
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_sets"
  end
end
```

This lazy evaluation means:
- The prefix is read from the configuration when a model first needs its table, not when the class is loaded, so the initializer's value applies whatever the load order
- Tests can use a different prefix than production (set it before the models run a query)

It does **not** make a change at runtime take effect: once a model has built a query, Active Record keeps its table (`arel_table`) and queries keep using the old name. Set the prefix in the initializer and restart.

## No Prefix — When to Use It

Use an empty prefix (`''`) when:
- You have an existing app with tables already named `permission_sets`, `resources`, etc.
- You prefer shorter table and column names
- You're the only gem using these table names

**Warning:** Without a prefix, ensure your app doesn't already have tables named `resources`, `permission_sets`, `resource_fields`, `resource_actions`, `permission_set_rules`, `permission_set_users`, `permission_set_groups`, `permission_set_group_users` or `audit_events`.

## Foreign Keys

The prefix applies to the table a reference points at, never to the column:

```ruby fragment
# With prefix 'permission_forge_':
t.references :permission_set, foreign_key: { to_table: :permission_forge_permission_sets }

# With prefix 'pf_':
t.references :permission_set, foreign_key: { to_table: :pf_permission_sets }

# With no prefix:
t.references :permission_set, foreign_key: { to_table: :permission_sets }
```

References to the host app's `users` table are never prefixed either — they always use `t.references :user`, typed like your user model's primary key (see `--user-id-type` in the [migration guide](migration-guide.md)).

### Installed with a prefix on 0.12.2 or earlier?

Those versions also prefixed the *columns* (`permission_forge_permission_set_id`), which the models never read, so an install with a non-empty prefix could not create or read any permission data. If you still have such a migration unapplied, delete it and run the generator again. If you applied it, rename the columns:

```ruby fragment
class FixPermissionForgeForeignKeys < ActiveRecord::Migration[7.1]
  PREFIX = 'permission_forge_'
  REFERENCES = {
    permission_sets: %w[permission_set_group], resources: %w[permission_set],
    resource_fields: %w[resource], resource_actions: %w[resource],
    permission_set_rules: %w[permission_set resource], permission_set_users: %w[permission_set],
    permission_set_group_users: %w[permission_set_group]
  }.freeze

  def change
    REFERENCES.each do |table, references|
      references.each { |ref| rename_column :"#{PREFIX}#{table}", :"#{PREFIX}#{ref}_id", :"#{ref}_id" }
    end
  end
end
```
