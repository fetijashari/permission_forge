require 'test_helper'

# Level 3 — end-to-end Postgres RLS enforcement.
#
# Runs ONLY against PostgreSQL (`DB=postgres bundle exec rake test:rls`);
# on other adapters every test skips. Assertions execute under a
# non-superuser role (`SET ROLE`) because superusers and table owners with
# BYPASSRLS are exempt from policies — testing as a superuser would prove
# nothing.
class RlsEnforcementTest < ActiveSupport::TestCase
  APP_ROLE = 'permission_forge_app'.freeze

  def self.postgres?
    ActiveRecord::Base.connection.adapter_name.match?(/postgresql/i)
  end

  setup do
    skip 'PostgreSQL-only enforcement suite (DB=postgres rake test:rls)' unless self.class.postgres?

    protect_only('Customer')
    @user = create_user
    @permission_set = create_permission_set
    create_permission_set_user(user: @user, permission_set: @permission_set)
    @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    create_permission_set_rule(permission_set: @permission_set, resource: @resource,
                               operator: 'equal', field_value: 'current_user', include_nulls: false)
    # Rows of the test tenant: the view_all bypass is tied to the row's
    # tenant when tenancy is on (the suite's permission rows are in it).
    @mine = create_customer(name: 'Mine', supplier_id: @user.id, account_id: DEFAULT_TEST_ACCOUNT.id)
    @other = create_customer(name: 'Other', supplier_id: @user.id + 999, account_id: DEFAULT_TEST_ACCOUNT.id)

    PermissionForge::RLS.sync!
    create_app_role
  end

  # A second granting set of the user with a Customer resource that has view_all.
  def grant_view_all(**attrs)
    PermissionForge.without_permission_scope do
      set = create_permission_set(name: "View all #{SecureRandom.hex(2)}")
      create_permission_set_user(user: @user, permission_set: set)
      create_resource(permission_set: set, name: 'Customer', view_all: true, **attrs)
    end
  end

  def visible_uuids
    as_app_role { PermissionForge::RLS.with_user(@user) { Customer.unscoped.pluck(:uuid) } }
  end

  # Pre-release review core-security #6: the policy's bypass ignored
  # Resource.is_active and the tenant.
  test 'a switched-off resource grants no view_all bypass at the DB layer, as at the app layer' do
    resource = grant_view_all

    assert_includes visible_uuids, @other.uuid

    PermissionForge.without_permission_scope { resource.update!(is_active: false) }
    Current.user = @user

    assert_not User.find(@user.id).can_view_all?(:Customer), 'the app layer stops bypassing'
    refute_includes visible_uuids, @other.uuid, 'and so does the policy'
    assert_includes visible_uuids, @mine.uuid
  end

  test 'a view_all grant in another tenant does not bypass the rules on this tenant rows, nor on rows of no tenant' do
    elsewhere = Account.create!(name: 'Elsewhere')
    previous = ActsAsTenant.test_tenant
    begin
      ActsAsTenant.test_tenant = elsewhere
      grant_view_all
    ensure
      ActsAsTenant.test_tenant = previous
    end
    homeless = PermissionForge.without_permission_scope { create_customer(name: 'Homeless', supplier_id: @user.id + 999) }
    theirs = PermissionForge.without_permission_scope do
      create_customer(name: 'Theirs', supplier_id: @user.id + 999, account_id: elsewhere.id)
    end

    uuids = visible_uuids
    refute_includes uuids, @other.uuid, 'a row of this tenant'
    refute_includes uuids, homeless.uuid, 'a row of no tenant'
    assert_includes uuids, theirs.uuid, 'a row of the tenant that grants view_all'
    assert_includes uuids, @mine.uuid
  end

  teardown do
    protected_model_names.replace(@protected_before) if @protected_before
    connection.execute('RESET ROLE') if self.class.postgres?
  end

  test 'unscoped is filtered by the database policy' do
    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        uuids = Customer.unscoped.pluck(:uuid)
        assert_includes uuids, @mine.uuid
        refute_includes uuids, @other.uuid
      end
    end
  end

  test 'raw SQL is filtered by the database policy' do
    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        names = connection.select_values('SELECT name FROM customers')
        assert_includes names, 'Mine'
        refute_includes names, 'Other'
      end
    end
  end

  test 'view_all bypasses rules dynamically (no resync needed)' do
    PermissionForge.without_permission_scope { @resource.update!(view_all: true) }

    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        assert_includes Customer.unscoped.pluck(:uuid), @other.uuid
      end
    end
  end

  test 'a consent-gated set granting view_all does NOT bypass rules at the DB layer' do
    PermissionForge.without_permission_scope do
      conditional_set = create_permission_set(name: 'Consent Gated',
                                              requires_session_flag: 'marketing_consent')
      create_permission_set_user(user: @user, permission_set: conditional_set)
      create_resource(permission_set: conditional_set, name: 'Customer', view_all: true)
    end
    PermissionForge::RLS.sync!

    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        # Rules from the base set still apply — the conditional view_all grant
        # must not widen DB-level access (its condition can't be checked in SQL).
        refute_includes Customer.unscoped.pluck(:uuid), @other.uuid
      end
    end
  end

  test 'a muting set cancels the view_all bypass dynamically' do
    PermissionForge.without_permission_scope do
      @resource.update!(view_all: true)
      muting_set = create_permission_set(name: 'Mute', is_muting: true)
      create_permission_set_user(user: @user, permission_set: muting_set)
      create_resource(permission_set: muting_set, name: 'Customer', view_all: true)
    end

    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        refute_includes Customer.unscoped.pluck(:uuid), @other.uuid
      end
    end
  end

  test 'revoking the assignment takes effect without a policy resync' do
    PermissionForge.without_permission_scope do
      PermissionForge::PermissionSetUser.where(user_id: @user.id).delete_all
    end

    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        # No rule-bearing memberships -> rules only restrict members -> all visible.
        uuids = Customer.unscoped.pluck(:uuid)
        assert_includes uuids, @mine.uuid
        assert_includes uuids, @other.uuid
      end
    end
  end

  test 'missing session variable follows :bypass strategy' do
    as_app_role do
      uuids = Customer.unscoped.pluck(:uuid)
      assert_includes uuids, @mine.uuid
      assert_includes uuids, @other.uuid
    end
  end

  test 'missing session variable hides all rows under :deny' do
    PermissionForge.configuration.nil_user_strategy = :deny
    PermissionForge::RLS.sync!

    as_app_role do
      assert_empty Customer.unscoped.pluck(:uuid)
    end
  ensure
    PermissionForge.configuration.nil_user_strategy = :bypass
  end

  test 'INSERTs are not blocked by policies' do
    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        record = Customer.create!(uuid: SecureRandom.uuid, name: 'New', email: 'n@example.com',
                                  domain: 'example.com', supplier_id: @user.id)
        assert record.persisted?
      end
    end
  end

  test 'drift report is in sync after sync! and stale after a rule edit' do
    report = PermissionForge::RLS.drift_report.find { |r| r[:table] == 'customers' }
    assert report[:in_sync], 'expected customers policies to be in sync right after sync!'

    PermissionForge.without_permission_scope do
      PermissionForge::PermissionSetRule.first.update!(field_value: '123')
    end

    report = PermissionForge::RLS.drift_report.find { |r| r[:table] == 'customers' }
    refute report[:in_sync], 'expected drift after editing rule content'
  end

  test 'remove! disables enforcement' do
    PermissionForge::RLS.remove!

    as_app_role do
      PermissionForge::RLS.with_user(@user) do
        assert_includes Customer.unscoped.pluck(:uuid), @other.uuid
      end
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def protected_model_names
    PermissionForge::Concerns::PermissionScopedFindable.protected_model_names
  end

  # sync! writes one set of policies per protected model, and a table has one
  # set. Other test files define more protected models on `customers`
  # (SoftDeleteFirstCustomer, TenantLastCustomer, ...). Once they are loaded — in
  # the full suite they are, under `rake test:rls` they are not — the last of
  # them, which has no rules, would replace the policies made for Customer.
  # These tests are about Customer, so only Customer is protected while they run.
  def protect_only(*names)
    @protected_before = protected_model_names.dup
    protected_model_names.replace(names)
  end

  def create_app_role
    connection.execute(<<~SQL)
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{APP_ROLE}') THEN
          CREATE ROLE #{APP_ROLE};
        END IF;
      END
      $$;
    SQL
    connection.execute("GRANT USAGE ON SCHEMA public TO #{APP_ROLE}")
    connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{APP_ROLE}")
    connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{APP_ROLE}")
  end

  # Assertions run as a plain role so policies actually apply; data setup and
  # sync happen beforehand as the connecting (privileged) user.
  def as_app_role
    connection.execute("SET ROLE #{APP_ROLE}")
    yield
  ensure
    connection.execute('RESET ROLE')
  end
end
