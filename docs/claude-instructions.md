# PermissionForge Notes for AI Coding Assistants

A snippet for host apps that use an AI coding assistant. Paste the block below into your project's `CLAUDE.md`, `AGENTS.md` or similar instructions file, so the assistant works with PermissionForge the way the gem actually behaves. Adjust the model names, the table prefix and the resolver to your app.

---

````markdown
## PermissionForge (authorization)

This app uses PermissionForge: Resource CRUD flags, field-level read/edit/mask, and row-level rules,
stored in database tables and managed in the PermissionForge admin. `User` includes
`PermissionForge::Concerns::PermissionedUser`.

### Adding PermissionForge to a model
1. Rows: include `PermissionForge::Concerns::PermissionScopedFindable` in the model if its rows need
   rules. Query through `Model.permission_scoped` (or class-level `find_by`), never a bare `where`.
2. Resource: create a `PermissionForge::Resource` named after the model in a Permission Set (admin, or
   `PermissionForge::Services::ResourceWithFieldsBuilder.call(permission_set:, resource_name: 'Customer')`,
   which grants full CRUD and read/edit on every column, unmasked, personal-data columns included: narrow it).
   The model's first Resource row auto-applies `MaskedAttributes` to it (in every process when the
   cache store is shared).
3. Fields: every column the user should read needs a field row; with `unconfigured_field_strategy :block`
   (the default) a column without one reads as hidden. `ResourceFieldGenerator.call(resource:)` creates
   one row per column with no access (personal-data columns masked-readable); open what is needed.
4. Controllers: call `can_*?` before acting, or include `ControllerActionGuard`; filter writes with
   `PermitsAttributes` (below) and hashes built outside the model with `FiltersResponseAttributes`.
5. Tests: cover a user without the set, a user with it, and a signed-out request.

### Where each tier is enforced
- **Resource CRUD flags** (`read_access`, `create_access`, `edit_access`, `delete_access`) guard nothing
  by themselves. They are enforced where code calls `user.can_read?(:Customer)`, `can_create?`,
  `can_edit?`, `can_delete?`, `can?(:export, :Customer)` (custom actions), or where a controller
  includes `PermissionForge::Concerns::ControllerActionGuard` (raises
  `PermissionForge::ActionNotAuthorizedError`).
- **Field access** comes from the field rows. `MaskedAttributes` (auto-applied to every model that has a
  Resource row) guards getters, `[]`, `read_attribute`, `attributes`, `as_json` / `to_json` and
  `inspect`. It does NOT guard `pluck`, raw SQL, `select("col AS alias")`, `*_before_type_cast`,
  `*_in_database`, dirty tracking (`*_was`, `changes`) or `Marshal`. Filter hashes from those paths with
  `PermissionForge::Services::FiltersResponseAttributes.call(attributes:, resource_name:)`.
- **Row-level rules** apply only to the class-level `Model.find_by` / `Model.find_by!` and
  `Model.permission_scoped`, on models that include `PermissionForge::Concerns::PermissionScopedFindable`.
  With `auto_query_scoping :off` (the default) these skip the rules: `where`, `all`, `find`,
  associations, `Model.where(...).find_by`, `association.find_by`, `Model.unscoped.find_by`,
  `find_sole_by`. For collections, start from `Model.permission_scoped`.
- A user with no rules for a model sees every row — also a signed-in user without Read on it, unless
  `config.no_read_access_strategy = :deny` (then no row). Rules from several granting sets intersect (AND).
  `view_all` / `modify_all` on a resource bypasses that resource's rules (for an STI subclass, only the
  rules of the entry that grants it).
- `find_by` returns `nil` for a missing record and raises
  `PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError` when a rule denies an
  existing one. `error.message` is a String; `error.details` holds the rule failure messages;
  `error.failure_messages` the rules' own `failure_message` texts. Both denial errors answer 403 when
  nothing rescues them; a `rescue_from` decides otherwise.
- With no current user: rules follow `config.nil_user_strategy` (default `:bypass` = no rules), masking
  follows `masked_attributes_nil_user_strategy` (default `:bypass` = raw values; `:hide`; the user model is exempt), `FiltersResponseAttributes` follows `response_filter_nil_user_strategy` (default
  `:bypass`), and `PermitsAttributes` returns `{}`.

### Writes
- Filter incoming params with
  `PermissionForge::Services::PermitsAttributes.call(resource: record_or_class, permitted_params: params)`.
  Pass params that are already permitted: it returns a plain Hash. A key the user may not edit is dropped
  whatever its value. Only `<assoc>_attributes` of an `accepts_nested_attributes_for` association is a
  nested payload: it is filtered against the child model's own resource (dropped when the user has no
  entry for it), a nested `id` is kept only when it names a row the child's rules let the user reach
  (else the whole record is dropped), and `_destroy` is kept only under the child's `delete_access`.

### Defaults that fail open (check `config/initializers/permission_forge.rb`)
- `nil_user_strategy :bypass`: no current user means no row rules (also in the RLS policy and, unless
  `action_guard_nil_user_strategy` is set, the controller guard).
- `response_filter_nil_user_strategy :bypass`, `masked_attributes_nil_user_strategy :bypass`,
  `auto_query_scoping :off`, `no_read_access_strategy :rules_only` (a signed-in user without Read on a
  model gets every row its rules allow, all of them with no rule),
  `conditional_sets_strict_mode false`, `extra_fields_default_access :grant`.
- `unconfigured_action_strategy` is `:block` (since 0.15): a guarded action no Permission Set manages is
  refused (403); unmapped controller actions are always allowed. `:allow` is an explicit opt-out that
  fails open: do not set it in code you write.
- `admin_assignment_authorization` and `audit_log_authorization` unset: any admin may assign and read
  the audit log.
- `cache_backend :memory`: per process; production needs a shared store.
- With `auto_query_scoping :filter_only`, the scope is decided when a relation is built: never keep a
  relation in a constant or build one before authentication (built with no user, it stays unscoped).
Do not loosen these in code you write. `bin/rails permission_forge:audit` reports most of them (not
`no_read_access_strategy`, `action_guard_nil_user_strategy`,
`admin_assignment_authorization` or `audit_log_authorization`).

### Caching and data
- Each user's permissions are cached (`user.permissions_hash`, read-through). Saving a permission record
  or assignment through ActiveRecord invalidates the affected users after the commit: do not add
  `regenerate_permissions` calls. After writes that skip callbacks (`update_all`, `insert_all`, raw SQL)
  call `user.invalidate_permissions` — and avoid such writes on the permission tables: they also write
  no audit event.
- Never change the shape of the cached hash: `{ profile:, preferences:, permissions: { resources:
  { Customer: { permissions:, fields:, actions:, source_permission_sets:, permission_set_rules: } } } }`.
  `source_permission_sets` is an Array of Hashes (`uuid`, `name`, `is_muting`,
  `permission_set_granted_by`, `permission_set_granted_at`, ...).
- Tables: 8 permission tables (`permission_sets`, `permission_set_users`, `permission_set_groups`,
  `permission_set_group_users`, `resources`, `resource_fields`, `resource_actions`,
  `permission_set_rules`) plus `audit_events`, all with `config.table_name_prefix`
  (default `permission_forge_`).
- Muting sets (`is_muting: true`) subtract after the granting sets are merged; muting a resource's read
  hides all its fields.
- Validations: edit requires read, delete requires read, modify_all requires view_all, mask requires
  read (not checked for muting sets).
- `config.current_user_resolver` decides who is signed in for the gem. The generated default is
  `-> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }`.
- In tests, creating a `PermissionForge::Resource` named after a model applies `MaskedAttributes` to
  that class for the rest of the process.
````

---

## Adjusting the snippet

1. **Model names**: replace `Customer` with the models your app protects.
2. **Table prefix**: if you set `config.table_name_prefix` (an empty prefix, say), change the table line.
3. **Current user**: if you wrote your own `current_user_resolver`, name it instead of the generated default.
4. **Your own conventions**: add where your app calls `can_*?`, which controllers use `ControllerActionGuard`, and whether `auto_query_scoping` is on.
