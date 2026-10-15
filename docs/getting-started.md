# Getting Started with PermissionForge

This guide walks you through setting up PermissionForge in a fresh Rails app from scratch. If you're new to permissions systems, start here.

## Prerequisites

Before you begin, make sure you have:
- A Rails 7.1+ application
- Ruby 3.2+
- A `User` model (any model works, but we'll use `User` in examples; it needs no `uuid` column)
- A shared cache store for production (Redis, Memcached or Solid Cache through `Rails.cache`); in development, `config.cache_store = :file_store, "tmp/cache/store"` lets a change made from a console or rake task reach the running server (Rails' default `:memory_store` is per process; see [Cache Consistency](./configuration.md#cache-consistency))

## Step 1: Install the Gem

Add PermissionForge to your `Gemfile`:

```ruby
gem 'permission_forge'
```

Run:

```bash
bundle install
```

## Step 2: Run the Install Generator

```bash
rails generate permission_forge:install
```

This creates two files and prints the next steps (the ones in this guide):
1. **`config/initializers/permission_forge.rb`** — your configuration file
2. **A migration** — creates all the database tables PermissionForge needs

Now run the migration:

```bash
rails db:migrate
```

Booting before `db:migrate` logs "audit_events is :auto but the table … was not found … (bin/rails db:migrate)"; it goes away once the migration has run.

> **Tip:** Check your database — you should see 9 new tables, all prefixed with `permission_forge_`: the 8 permission tables and the audit log (`permission_forge_audit_events`).

> **UUID primary keys?** The generator reads your `User` model's primary key type and types `user_id` (and the audit columns) to match, so run it after your users table exists. To set it yourself: `rails generate permission_forge:install --user-id-type=uuid`.

## Step 3: Configure the Gem

Open `config/initializers/permission_forge.rb`. The most important settings are:

```ruby
PermissionForge.configure do |config|
  # Tell PermissionForge which model represents your users
  config.user_class = 'User'

  # Tell PermissionForge how to find the currently logged-in user.
  # As generated, it reads Current.user when your app has a Current class
  # that answers `user`, and nil otherwise:
  config.current_user_resolver = -> { ::Current.user if defined?(::Current) && ::Current.respond_to?(:user) }

  # The safe part of the hardening checklist, written by the generator:
  config.action_guard_nil_user_strategy = :deny   # the controller guard refuses signed-out requests
  config.conditional_sets_strict_mode = true      # conditional sets need a request context (see Activation Conditions)

  # For production, use Rails.cache (works with Redis, SolidCache, Memcached, ...):
  config.cache_backend = :rails_cache

  # :memory (or Rails' development :memory_store) is per process: a change
  # made from a console or rake task does not reach a running server.
  # config.cache_backend = :memory

  # Closes the remaining fail-open defaults at a cost for code that runs with
  # nobody signed in (jobs, mailers, seeds): see Presets in the configuration guide.
  # config.preset = :strict
end
```

Configure PermissionForge in `config/initializers` only. Its models (`PermissionForge::PermissionSet`, ...) are autoloaded by your application right after the initializers, so an initializer must not name one at the top level (the boot fails with a `NameError` that says so): reference them from a method, from `Rails.application.config.to_prepare`, or from your models, controllers, jobs and rake tasks. `user_class`, `audit_user_class` and `tenant_model` are read as the models load; a change made later is logged and does not reach a loaded class. The generated initializer is short on purpose: every other option, with its default, is in the [Configuration guide](./configuration.md).

### What does `current_user_resolver` mean?

PermissionForge needs to know who the "current user" is whenever it checks permissions. The `current_user_resolver` is a lambda (a small piece of code) that returns the current user.

A `Current` class is optional. The generated resolver works with Rails 8's authentication generator (its `Current` answers `user`) and with any `ActiveSupport::CurrentAttributes` class that has a `user` attribute. Without one, write your own resolver. **Until the resolver returns your signed-in user, nobody is signed in as far as PermissionForge knows, and `nil_user_strategy` decides — with the default `:bypass`, nothing is restricted.**

**Your own resolver:**

```ruby
# A CurrentAttributes class of your own with a `user` attribute (recommended):
config.current_user_resolver = -> { Current.user }
```

> **Security:** do not resolve the user from a bare `Thread.current[:current_user]` (or a class variable) that your code sets. Application servers reuse threads, and nothing clears such a variable between requests, so a request that does not set it (an unauthenticated one, an error path, a job) resolves the *previous* request's user and gets that user's permissions. Use `ActiveSupport::CurrentAttributes`, which Rails resets before and after every request and job. If you must use your own variable, set it in an `around_action` and clear it in `ensure`.

## Step 4: Add PermissionForge to Your User Model

Open your User model and add this line:

```ruby
class User < ApplicationRecord
  include PermissionForge::Concerns::PermissionedUser

  # ... your existing code
end
```

> **Do not include `PermissionScopedFindable` in your user model.** Sign-in, session restore, password reset and confirmation run before anyone is signed in, and under `nil_user_strategy = :deny` their lookups find nothing. Scope a user directory with `User.permission_scoped` in its controller.
>
> **User model contract:** PermissionForge needs *something* to show for each person in the admin (People list, person picker, audit). It auto-discovers `:name` → `:full_name` → `:display_name` → `first_name`/`last_name` (or `firstname`/`lastname`) → `:email` or `:email_address`, the column Rails 8's `bin/rails generate authentication` creates (any can be a column **or** a Ruby method/virtual attribute), falling back to `User #<id>`. People are searched by whichever of `name`, `email`, `email_address`, `full_name`, `display_name`, `first_name`/`last_name`, `firstname`/`lastname`, `username`, `login` exist as columns.
>
> If the defaults don't fit, override `config.user_label_formatter` and/or `config.user_list_resolver` — see [Configuration](./configuration.md).

This gives your User model these methods:
- `user.can_read?('Customer')` — can this user view customers?
- `user.can_create?('Customer')` — can this user create customers?
- `user.can_edit?('Customer')` — can this user update customers?
- `user.can_delete?('Customer')` — can this user delete customers?
- `user.permissions_hash` — get the full cached permission data (rebuilt automatically on cache miss)

## Step 5: Create Your First Permission Set

A **Permission Set** is like a "role on steroids." While a traditional role just says "you're an admin," a Permission Set says exactly what you can see and do, down to individual fields.

Open the Rails console:

```bash
rails console
```

```ruby
# 1. Create a permission set
sales_pset = PermissionForge::PermissionSet.create!(
  name: 'Sales Team',
  description: 'Permissions for the sales department',
  is_active: true
)
puts "Created: #{sales_pset.name} (#{sales_pset.uuid})"

# 2. Add a resource — this says "the Sales Team can interact with Customers"
customer_resource = PermissionForge::Resource.create!(
  permission_set: sales_pset,
  name: 'Customer',        # Must match your model class name exactly!
  read_access: true,        # Can view customers
  create_access: true,      # Can create customers
  edit_access: true,         # Can update customers
  delete_access: false       # Cannot delete customers
)
puts "Added resource: #{customer_resource.name}"

# 3. Add field-level permissions
#    This controls which columns the user can see and edit
PermissionForge::ResourceField.create!(
  resource: customer_resource,
  name: 'name',              # Must match the database column name
  label: 'Customer Name',    # Human-readable label
  read_access: true,
  edit_access: true
)

PermissionForge::ResourceField.create!(
  resource: customer_resource,
  name: 'email',
  label: 'Email Address',
  read_access: true,
  edit_access: false  # Can see email but not change it
)

# 4. Assign a user to this permission set
user = User.first  # or however you find your user
PermissionForge::PermissionSetUser.create!(
  permission_set: sales_pset,
  user: user
)

# 5. Now test it! Permissions are built and cached automatically on the
#    first check (read-through caching) — no manual step needed.
puts user.can_read?('Customer')   # => true
puts user.can_delete?('Customer') # => false
```

> **Note:** You don't need to refresh permissions by hand. Changes to permission sets, resources, fields, rules, and user assignments automatically invalidate the affected users' cached permissions after the commit, and the hash is rebuilt on the next permission check (read-through caching).

## Step 6: Verify It Works

```ruby
# In the console:
user = User.first

# Check resource-level permissions
user.can_read?('Customer')   # => true
user.can_create?('Customer') # => true
user.can_edit?('Customer')   # => true
user.can_delete?('Customer') # => false

# Get all permissions for a resource
user.permissions_for(:Customer)
# => { read_access: true, create_access: true, edit_access: true,
#      delete_access: false, view_all: false, modify_all: false }

# Get field-level details
entry = user.permissions_hash_for(:Customer)
entry[:fields]
# => { name:  { read_access: true, edit_access: true,  mask_access: false, mask_strategy: 'full' },
#      email: { read_access: true, edit_access: false, mask_access: false, mask_strategy: 'full' } }
```

## Wiring a scaffold

A controller made by `bin/rails generate scaffold` needs two changes before the permissions show in it. Masked fields appear masked right away, which makes the first run look protected while it is not:

- **Row-level rules.** `PermissionScopedFindable` applies the user's rules to the class-level `find_by` / `find_by!` and to `permission_scoped` only. The scaffold's `Customer.all` (index) and `Customer.find` (`set_customer`) ignore them: every user lists every row and opens any record by its URL. Use the scoped calls:

  ```ruby
  def index
    @customers = Customer.permission_scoped # was Customer.all
  end

  private

  def set_customer
    @customer = Customer.find_by!(id: params[:id]) # was Customer.find: a denied record raises NotAuthorizedError (403)
  end
  ```

  Or turn on [query scoping](./query-scoping.md) (`auto_query_scoping = :filter_only`) so that `all` and `find` are scoped too.
- **JSON views.** The scaffold's jbuilder partial calls `json.extract!`, which calls each getter: a field the user may not read comes out as `"notes": null`, so a client cannot tell hidden from empty. `as_json` leaves hidden fields out (`omit_hidden_in_attributes_hash`, the default), so build the partial from it:

  ```ruby
  # app/views/customers/_customer.json.jbuilder
  json.merge! customer.as_json(only: %i[id name email status notes created_at updated_at])
  json.url customer_url(customer, format: :json)
  ```

The forms still offer every field: see [Telling the user what was not saved](./field-filtering.md#telling-the-user-what-was-not-saved) for rendering a field read-only and saying which keys `PermitsAttributes` dropped. And with nobody signed in the model layer restricts nothing by default: see the [hardening checklist](../README.md#production-hardening-checklist).

## Step 7: Open the Admin UI

The admin UI is where a business owner manages Permission Sets, people and assignments without the console. Mount it in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount PermissionForge::Engine, at: "/permissions"
end
```

It is behind HTTP Basic auth and answers **401** until credentials are set. The generated initializer has them commented under "Admin screens", Option A; uncomment the two lines:

```ruby
config.http_basic_auth_user     = ENV['PF_ADMIN_USER']
config.http_basic_auth_password = ENV['PF_ADMIN_PASSWORD']
```

Restart the server with `PF_ADMIN_USER` and `PF_ADMIN_PASSWORD` set and open `http://localhost:3000/permissions`. To sign admins in with your app's own authentication instead (Option B, `base_controller_class`), see [Admin UI](./admin-ui.md#disabling-http-basic-auth). Before production, run `bin/rails permission_forge:audit`: it lists the settings and data that are still open.

## Using Rails 8's authentication generator

If your app was set up with `bin/rails generate authentication`, the generated `current_user_resolver` already reads its `Current.user`, so it needs no change. Two things to know:

- **Public actions.** `allow_unauthenticated_access` skips `require_authentication`, which is what resumes the session, so on those actions `Current.user` is `nil` even for a signed-in visitor. The controller action guard then treats them as signed out, and row-level rules and masking follow the nil-user strategies (the default `:bypass` restricts nothing). Add `prepend_before_action :resume_session, only: ...` for the same actions: see [Controller Actions](./controller-actions.md#callback-order).
- **Your own admin controller.** An admin controller that inherits from your `ApplicationController` (`base_controller_class`, Option B) also inherits the generated `request_authentication`, which redirects to `new_session_path`. That path does not resolve inside the engine, so a signed-out visit to `/permissions` is a 500. Override it to use `main_app.new_session_path`: see [Admin UI](./admin-ui.md#rails-8-authentication-generator).

## What's Next?

Now that you have basic permissions working, here are the next steps:

- **[Row-Level Rules](./row-level-rules.md)** — restrict which records a user can see
- **[Field Filtering](./field-filtering.md)** — automatically strip unauthorized fields from API responses
- **[Permission Set Groups](./permission-set-groups.md)** — organize permission sets into groups
- **[Tips and Helpers](./tips-and-helpers.md)** — useful patterns, debugging, and common gotchas

## Troubleshooting

### "permissions_hash shows no resources"

`permissions_hash` is read-through — a cache miss rebuilds the hash automatically, so an empty `permissions[:resources]` means the user genuinely has no effective permissions. Check:
- The user is assigned to a permission set (a `PermissionSetUser` record exists)
- The assignment hasn't expired (`expires_at` is `nil` or in the future)
- The permission set has `is_active: true`

### "can_read? always returns false"

1. Check that the permission set has `is_active: true`
2. Check that the resource has `is_active: true`
3. Make sure the resource `name` exactly matches the model class name (case-sensitive!)
4. Load the user again (`User.find(id)` or `user.reload`): a user object keeps the hash it has read, so in a console it does not see a change made in another process (the admin UI, say) until it reads again

### "Testing permissions in your app"

PermissionForge doesn't ship FactoryBot factories — create the permission records directly with the model classes (`PermissionForge::PermissionSet`, `PermissionForge::Resource`, etc.). See [Testing](./testing.md) for a full Minitest example.
