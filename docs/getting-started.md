# Getting Started with PermissionForge

This guide walks you through setting up PermissionForge in a fresh Rails app from scratch. If you're new to permissions systems, start here.

## Prerequisites

Before you begin, make sure you have:
- A Rails 7.1+ application. Steps 1–7 work on 7.1 and later. [Wiring a scaffold](#wiring-a-scaffold) and [Using Rails 8's authentication generator](#using-rails-8s-authentication-generator) show the code Rails 8 generates (`params.expect`, `bin/rails generate authentication`, `Current.session`); each says what to write on Rails 7.x
- Ruby 3.2+
- A `User` model (any model works, but we'll use `User` in examples; it needs no `uuid` column)
- A shared cache store for production (Redis, Memcached or Solid Cache through `Rails.cache`); in development, `config.cache_store = :file_store, "tmp/cache/store"` lets a change made from a console or rake task reach the running server (Rails' default `:memory_store` is per process; see [Cache Consistency](./configuration.md#cache-consistency))

## Step 1: Install the Gem

Add PermissionForge to your `Gemfile`:

```ruby fragment
gem 'permission_forge'
```

Run:

```bash run
bundle install
```

## Step 2: Run the Install Generator

```bash run
rails generate permission_forge:install
```

This creates two files and prints the next steps (the ones in this guide):
1. **`config/initializers/permission_forge.rb`** — your configuration file
2. **A migration** — creates all the database tables PermissionForge needs

Now run the migration:

```bash run
rails db:migrate
```

Booting before `db:migrate` logs "audit_events is :auto but the table … was not found … (bin/rails db:migrate)"; it goes away once the migration has run.

> **Tip:** Check your database — you should see 9 new tables, all prefixed with `permission_forge_`: the 8 permission tables and the audit log (`permission_forge_audit_events`).

> **UUID primary keys?** The generator reads your `User` model's primary key type and types `user_id` (and the audit columns) to match, so run it after your users table exists. To set it yourself: `rails generate permission_forge:install --user-id-type=uuid`.

## Step 3: Configure the Gem

Open `config/initializers/permission_forge.rb`. The most important settings are:

```ruby fragment
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

> **Seeds under `config.preset = :strict`.** Code that runs with nobody signed in (seeds, jobs, the console) then sees no protected rows, so an idempotent seed such as `Customer.find_or_create_by!(name: 'Acme')` finds nothing and creates a duplicate on every run. Run it with a user, or inside `PermissionForge.without_permission_scope { }`: see [Presets](./configuration.md#presets).

Configure PermissionForge in `config/initializers` only. Its models (`PermissionForge::PermissionSet`, ...) are autoloaded by your application right after the initializers, so an initializer must not name one at the top level (the boot fails with a `NameError` that says so): reference them from a method, from `Rails.application.config.to_prepare`, or from your models, controllers, jobs and rake tasks. `user_class`, `audit_user_class` and `tenant_model` are read as the models load; a change made later is logged and does not reach a loaded class. The generated initializer is short on purpose: every other option, with its default, is in the [Configuration guide](./configuration.md).

### What does `current_user_resolver` mean?

PermissionForge needs to know who the "current user" is whenever it checks permissions. The `current_user_resolver` is a lambda (a small piece of code) that returns the current user.

A `Current` class is optional. The generated resolver works with Rails 8's authentication generator (its `Current` answers `user`) and with any `ActiveSupport::CurrentAttributes` class that has a `user` attribute. Without one, write your own resolver. **Until the resolver returns your signed-in user, nobody is signed in as far as PermissionForge knows, and `nil_user_strategy` decides — with the default `:bypass`, nothing is restricted.**

**Your own resolver:**

```ruby fragment
# A CurrentAttributes class of your own with a `user` attribute (recommended):
config.current_user_resolver = -> { Current.user }
```

> **Security:** do not resolve the user from a bare `Thread.current[:current_user]` (or a class variable) that your code sets. Application servers reuse threads, and nothing clears such a variable between requests, so a request that does not set it (an unauthenticated one, an error path, a job) resolves the *previous* request's user and gets that user's permissions. Use `ActiveSupport::CurrentAttributes`, which Rails resets before and after every request and job. If you must use your own variable, set it in an `around_action` and clear it in `ensure`.

## Step 4: Add PermissionForge to Your User Model

Open your User model and add this line:

```ruby fragment
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

```bash run
rails console
```

```ruby run
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

# 4. Assign a user to this permission set. Look the person up by email: User.first may be
#    someone else (the checks below and Step 6 use this same person)
user = User.find_by!(email_address: 'bob@example.com') # the person who gets the set (`email:` on a Devise app)
PermissionForge::PermissionSetUser.create!(
  permission_set: sales_pset,
  user: user
)

# 5. Now test it! Permissions are built and cached automatically on the
#    first check (read-through caching) — no manual step needed.
user.can_read?('Customer')   # => true
user.can_delete?('Customer') # => false
```

> **Note:** You don't need to refresh permissions by hand. Changes to permission sets, resources, fields, rules, and user assignments automatically invalidate the affected users' cached permissions after the commit, and the hash is rebuilt on the next permission check (read-through caching).

## Step 6: Verify It Works

Check the person Step 5 assigned. `User.first` may be someone else, who holds no Permission Set (one you assigned in the admin, for example): every check below then answers `false` and `{}`, with nothing to say why.

```ruby run
# In the console:
user = User.find_by!(email_address: 'bob@example.com') # the person you assigned in Step 5

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

A controller made by `bin/rails generate scaffold` needs a few changes before the permissions show in it. Masked fields appear masked right away, which makes the first run look protected while it is not:

- **Include the two concerns.** The model needs `PermissionScopedFindable` for its row-level rules (the controller below calls `Customer.permission_scoped`), and `ApplicationController` needs `ControllerActionGuard`, which checks the resource's CRUD flags before each REST action of every controller that inherits from it (`index` and `show` need `read_access`, ...; see [Controller Actions](./controller-actions.md)). Masking needs nothing here: it is applied to a model as soon as a Resource row names it (`auto_apply_masked_attributes`). The model, with the scaffold's `belongs_to :owner` pointed at `User` (`owner:references` names no model of its own):

  ```ruby file=app/models/customer.rb
  class Customer < ApplicationRecord
    include PermissionForge::Concerns::PermissionScopedFindable

    belongs_to :owner, class_name: 'User'
  end
  ```

  The scaffold's migration needs the same change before `bin/rails db:migrate`: `owner:references` writes `t.references :owner, null: false, foreign_key: true`, a foreign key to a table `owners`, and the first insert fails (`no such table: main.owners` on SQLite). Point it at the users table: `t.references :owner, null: false, foreign_key: { to_table: :users }`.

  And one line in `ApplicationController`, after `include Authentication` when you use Rails 8's authentication generator (the session must be resumed before the guard runs). [Handling Denials](./row-level-rules.md#rescuing-them-yourself) shows the whole file, with the handler that answers a denial in your layout; read [Using Rails 8's authentication generator](#using-rails-8s-authentication-generator) before you deploy it — the guard also reaches the sign-in page:

  ```ruby fragment
  class ApplicationController < ActionController::Base
    include Authentication
    include PermissionForge::Concerns::ControllerActionGuard # after Authentication
    # ... the rest of the file as the generator wrote it
  end
  ```

- **Row-level rules and the write path.** `PermissionScopedFindable` applies the user's rules to the class-level `find_by` / `find_by!` and to `permission_scoped` only. The scaffold's `Customer.all` (index) and `Customer.find` (`set_customer`) ignore them: every user lists every row and opens any record by its URL. And the scaffold's `customer_params` saves every column the form posts, whatever the user's field rows say. The controller as generated, with the three lines changed (the guard in `ApplicationController` checks the resource's CRUD flags for each REST action; the rules narrow the rows; `PermitsAttributes` drops the fields the user may not edit):

  ```ruby file=app/controllers/customers_controller.rb
  class CustomersController < ApplicationController
    before_action :set_customer, only: %i[ show edit update destroy ]

    # GET /customers or /customers.json
    def index
      @customers = Customer.permission_scoped # was Customer.all: the user's row-level rules apply
    end

    # GET /customers/1 or /customers/1.json
    def show
    end

    # GET /customers/new
    def new
      @customer = Customer.new
    end

    # GET /customers/1/edit
    def edit
    end

    # POST /customers or /customers.json
    def create
      @customer = Customer.new(customer_params)

      respond_to do |format|
        if @customer.save
          format.html { redirect_to @customer, notice: "Customer was successfully created." }
          format.json { render :show, status: :created, location: @customer }
        else
          format.html { render :new, status: :unprocessable_content }
          format.json { render json: @customer.errors, status: :unprocessable_content }
        end
      end
    end

    # PATCH/PUT /customers/1 or /customers/1.json
    def update
      respond_to do |format|
        if @customer.update(customer_params)
          format.html { redirect_to @customer, notice: "Customer was successfully updated.", status: :see_other }
          format.json { render :show, status: :ok, location: @customer }
        else
          format.html { render :edit, status: :unprocessable_content }
          format.json { render json: @customer.errors, status: :unprocessable_content }
        end
      end
    end

    # DELETE /customers/1 or /customers/1.json
    def destroy
      @customer.destroy!

      respond_to do |format|
        format.html { redirect_to customers_path, notice: "Customer was successfully destroyed.", status: :see_other }
        format.json { head :no_content }
      end
    end

    private
      # Use callbacks to share common setup or constraints between actions.
      def set_customer
        @customer = Customer.find_by!(id: params.expect(:id)) # was Customer.find: a denied record raises NotAuthorizedError (403)
      end

      # Only allow a list of trusted parameters through — and, of those, only the fields this user may edit.
      def customer_params
        permitted = params.expect(customer: [ :name, :email, :phone, :status, :notes, :owner_id ])
        PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: permitted)
      end
  end
  ```

  On Rails 7.x, where the scaffold has no `params.expect`, the two private methods read `Customer.find_by!(id: params[:id])` and `permitted = params.require(:customer).permit(:name, :email, :phone, :status, :notes, :owner_id)`; the rest is the same (an older scaffold writes `:unprocessable_entity` where this one writes `:unprocessable_content`: the same 422).

  Or turn on [query scoping](./query-scoping.md) (`auto_query_scoping = :filter_only`) so that `all` and `find` are scoped too. `PermitsAttributes` returns a plain Hash with the keys the user's field rows let through (a key without a row is dropped under the default `unconfigured_field_strategy = :block`); see [Field Filtering](./field-filtering.md) for telling the user what was not saved.
- **JSON views.** The scaffold's jbuilder partial calls `json.extract!`, which calls each getter: a field the user may not read comes out as `"notes": null`, so a client cannot tell hidden from empty. `as_json` leaves out a field whose row is **Hidden** (read off; `omit_hidden_in_attributes_hash`, the default), so build the partial from it. `only:` is the column list the scaffold's `json.extract!` line had (here a `Customer` scaffold with `name`, `email`, `phone`, `status`, `notes` and `owner:references`), so the JSON keeps its shape:

  ```ruby file=app/views/customers/_customer.json.jbuilder
  # app/views/customers/_customer.json.jbuilder
  json.merge! customer.as_json(only: %i[id name email phone status notes owner_id created_at updated_at])
  json.url customer_url(customer, format: :json)
  ```

  A column with **no row at all** is not left out. The default `unconfigured_field_strategy = :block` refuses it too, but `as_json` keeps its key with `null` (see [Unconfigured fields](./masked-attributes.md#unconfigured-fields)). Step 5 creates rows for `name` and `email` only, so `phone`, `status`, `notes`, `owner_id` and the timestamps come out as `null`. Give every column a row, so that each one is either readable or left out: the admin's **Sync fields with model** ("Add all new as Hidden", "… as Read-only" or "… with full access"), or in a console `PermissionForge::Services::ResourceFieldGenerator.call(resource: customer_resource)`. The generator adds a row for each column that has none: Hidden, `created_at` / `updated_at` included — also the columns that look like personal data, which get their recommended mask strategy on the row for when you open them (through 0.14.1 they came back readable and masked). `grant_all: true` makes them all readable and editable, unmasked, and the timestamps read-only (see [Rails timestamps](./masked-attributes.md#rails-timestamps)). The admin's **Sync fields with model** writes the same rows: "Add all new as Hidden" is the generator without `grant_all`, "… with full access" is `grant_all: true`, and "… as Read-only" starts the personal-data columns Masked under `gdpr_defaults`. Then open the fields the set should read.

- **HTML views.** The scaffold's `_customer.html.erb` prints a label and a getter for each column, so a field the user may not read still shows its label with a blank value (`Notes:` and nothing after it). Ask the user's field permissions and skip those fields, with a helper:

  ```ruby file=app/helpers/customers_helper.rb
  # app/helpers/customers_helper.rb
  module CustomersHelper
    # true when the signed-in user may read the Customer field (masked or not). A field without a
    # row answers nil, so false: the default unconfigured_field_strategy (:block) refuses it too.
    def customer_field_readable?(field)
      Current.user&.field_permissions(:Customer, field)&.dig(:read_access) == true
    end
  end
  ```

  ```erb file=app/views/customers/_customer.html.erb
  <%# app/views/customers/_customer.html.erb: one block per column, shown only when the user may read the field %>
  <div id="<%= dom_id customer %>">
    <% %i[name email phone status notes owner_id].each do |field| %>
      <% next unless customer_field_readable?(field) %>
      <div>
        <strong><%= Customer.human_attribute_name(field) %>:</strong>
        <%= customer.public_send(field) %> <%# masked by MaskedAttributes when the field is masked %>
      </div>
    <% end %>
  </div>
  ```

  `field_permissions(resource, field_name)` returns the field's entry (`read_access`, `edit_access`, `mask_access`, `mask_strategy`) or `nil` when the user's sets give the field no row. With nobody signed in the helper answers `false` and the partial shows no field, while the getters follow `masked_attributes_nil_user_strategy`.

The forms still offer every field: see [Telling the user what was not saved](./field-filtering.md#telling-the-user-what-was-not-saved) for rendering a field read-only and saying which keys `PermitsAttributes` dropped. And with nobody signed in the model layer restricts nothing by default: see the [hardening checklist](../README.md#production-hardening-checklist).

## Step 7: Open the Admin UI

The admin UI is where a business owner manages Permission Sets, people and assignments without the console. Mount it in `config/routes.rb`:

```ruby fragment
Rails.application.routes.draw do
  mount PermissionForge::Engine, at: "/permissions"
end
```

It is behind HTTP Basic auth and answers **401** until credentials are set. The generated initializer has them commented under "Admin screens", Option A; uncomment the two lines:

```ruby fragment
config.http_basic_auth_user     = ENV['PF_ADMIN_USER']
config.http_basic_auth_password = ENV['PF_ADMIN_PASSWORD']
```

Restart the server with `PF_ADMIN_USER` and `PF_ADMIN_PASSWORD` set and open `http://localhost:3000/permissions`. To sign admins in with your app's own authentication instead (Option B, `base_controller_class`), see [Admin UI](./admin-ui.md#disabling-http-basic-auth). Before production, run `bin/rails permission_forge:audit`: it lists the settings and data that are still open.

## Using Rails 8's authentication generator

`bin/rails generate authentication` is Rails 8's (on Rails 7.x use your own sign-in or Devise, and point `current_user_resolver` at its user: see [Step 3](#step-3-configure-the-gem)). If your app was set up with it, the generated `current_user_resolver` already reads its `Current.user`, so it needs no change. Three things to know:

- **The guard in `ApplicationController` guards the sign-in page too.** The generator's `SessionsController` maps to its `Session` model, so with `ControllerActionGuard` included in `ApplicationController` and `action_guard_nil_user_strategy = :deny` (what the install generator writes), a signed-out visitor is refused the sign-in form. The symptom: nobody can sign in, and Sign out ends the session but lands on the refused sign-in page. With the [Handling Denials](./row-level-rules.md#rescuing-them-yourself) handler that page is the 403 page ("You are not allowed to see this page. Sign in to see it.") where the form should be; with a handler that answers an empty 403, **Sign out seems to do nothing**: the page stays as it was, "Signed in as …" still in the header. Leave the sign-in pages out of the guard in the initializer:

  ```ruby fragment
  config.controller_discovery_exclude += %w[sessions passwords]
  ```

  See [Handling Denials](./row-level-rules.md#rescuing-them-yourself) for a handler that never loops and shows the 403 page in your layout, so that a signed-in person who holds no Permission Set reads why (and can sign out) instead of landing back on the sign-in form. The same section has the one line for `SessionsController#new` that sends a signed-in visitor on: after a Turbo sign-in the address bar still shows `/session/new`, and without it Reload brings back the sign-in form although the session is valid.
- **Public actions.** `allow_unauthenticated_access` skips `require_authentication`, which is what resumes the session, so on those actions `Current.user` is `nil` even for a signed-in visitor. On a guarded public action a signed-in user is refused as signed out: with the [Handling Denials](./row-level-rules.md#rescuing-them-yourself) handler they get the 403 page ("You are not allowed to see this page") although they are signed in and may hold the permissions — and a handler that sent every signed-out denial to the sign-in page (the version documented through 0.14.1) looped between the page and the sign-in page, whose `SessionsController#new` sends a signed-in visitor back. If the guard is skipped there, row-level rules and masking follow the nil-user strategies (the default `:bypass` restricts nothing). Required on every guarded action you open this way: `prepend_before_action :resume_session, only: ...` for the same actions (see [Callback order](./controller-actions.md#callback-order)); the visitor then gets the page, with their permissions.
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
