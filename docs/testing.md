# Testing

## Testing in Your App

Create the permission records with the model classes, as your app would. PermissionForge ships no factories or test helpers for host apps (the gem's own `create_user` and friends live in its test suite and are not loaded in yours).

Example Minitest setup (for host apps):

```ruby fragment
class CustomerPermissionsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(name: 'Test User', email: 'test@example.com') # or a fixture / factory of your own
    @permission_set = PermissionForge::PermissionSet.create!(name: 'Test', is_active: true)
    @resource = PermissionForge::Resource.create!(permission_set: @permission_set, name: 'Customer', read_access: true)
    PermissionForge::ResourceField.create!(resource: @resource, name: 'name', read_access: true, edit_access: true)
    PermissionForge::PermissionSetUser.create!(user: @user, permission_set: @permission_set)
  end

  test 'can read customers' do
    assert @user.can_read?('Customer')
    assert_not @user.can_delete?('Customer')
  end

  test 'checks custom actions' do
    PermissionForge::ResourceAction.create!(resource: @resource, name: 'export', is_permitted: true)
    assert @user.can?(:export, :Customer)
  end

  test 'checks masked fields' do
    PermissionForge::ResourceField.create!(resource: @resource, name: 'email',
                                           read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email')
    assert @user.masked_field?(:Customer, :email)
    assert_equal 'email', @user.mask_strategy_for(:Customer, :email)
  end
end
```

`uuid` is filled in for you, and no `regenerate_permissions` call is needed: creating, changing or destroying a permission record or an assignment invalidates the affected users' cached permissions after the commit (also inside Rails' transactional tests), and the next check rebuilds them. Use your own `User` model's attributes; it needs no `uuid` column. The `name: 'Customer'` Resource row also auto-applies `MaskedAttributes` to your `Customer` model for the rest of the test process.

### Parallel tests and configuration

`parallelize` forks your test workers: with `cache_backend = :memory` each worker has its own cache, which is what you want in tests. A shared store (Redis) is shared by every worker, so a permission change in one worker invalidates the entries another reads; use `:memory` in the test environment, or a separate Redis database or `cache_key_prefix` per worker. A test that changes `PermissionForge.configuration` should put the value back in `teardown`; the setting stays for the rest of the worker's process otherwise.

## Running the Gem's Own Suite

For contributors, from a checkout of the gem:

```bash fragment
bundle install
bundle exec rake test
```

The suite runs on SQLite by default. It also runs on MySQL (`DB=mysql BUNDLE_GEMFILE=gemfiles/mysql.gemfile`, with `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`) and PostgreSQL (`DB=postgres`; `rake test:rls` for the row-level security policy tests).

The SQLite suite runs in forked workers (`test/support/parallel_workers.rb`: 8 by default, about 30 seconds instead of about 2 minutes; `PARALLEL_WORKERS=1` runs one process). PostgreSQL, MySQL and Rails before 8.1 run serial. Each worker starts from a copy of the parent's in-memory database. A test that uses something every worker shares (the local Redis database 15, a fixed path) includes `ParallelWorkers::SharedResource` or uses a per-process path.

**Configuration snapshot.** `test_helper.rb` configures the suite's base (memory cache, no table prefix, `audit_trail_enabled` off — the created-by / updated-by stamps, not the audit event log, which stays on —, tenancy on) once, in its `configure` block. `ConfigurationSnapshot` (`test/support/configuration_snapshot.rb`) puts exactly that back before and after every test, also after `PermissionForge.reset!` or an in-place change (`custom_mask_strategies[:x] = 1`), so a test that raises in its teardown leaks nothing into the next. A new suite-wide setting goes in the `configure` block, never in a per-test reset. Other state (cache, owed invalidations, audit context, tenant, locale, `Current`, `Rails.logger`) is reset by name in `test_helper.rb`.

**Rails internals canary.** `test/permission_forge/rails_internals_canary_test.rb` has one test per private or undocumented Rails API the gem relies on, each naming the gem code that relies on it. Run it first after a Rails upgrade and on each `gemfiles/rails_*.gemfile`; CI runs it on Rails `main` in an allow-failure job. For example:

```bash fragment
BUNDLE_GEMFILE=gemfiles/rails_main.gemfile bundle exec ruby -Itest -e 'require "test_helper"; SimpleCov.minimum_coverage(0); require "./test/permission_forge/rails_internals_canary_test.rb"'
```

**Admin UI checks.** `html/no_hand_marked_safe_test.rb` lexes Ruby with Ripper (templates compiled by Erubi first) and fails on `html_safe`, `safe_concat`, `<%==`, `SafeBuffer`, `render inline:` or a `raw` call in `app/` or `lib/` (the allow-list is empty). `html/admin_script_hygiene_test.rb` fails on `var`, `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `eval` in `pf_admin.js`. `html/admin_accessibility_test.rb` lints every admin page and fragment (one h1, heading order, names, labelled tables, live toasts). For contrast and computed roles run axe-core in headless Chrome over the same pages.
