require 'test_helper'

module PermissionForge
  module Concerns
    class TenantScopingTest < ActiveSupport::TestCase
      setup do
        enable_tenant!
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
      end

      teardown do
        disable_tenant!
      end

      # --- Model scoping: records are tenant-isolated ---

      test 'permission sets are scoped to current tenant' do
        ActsAsTenant.test_tenant = @tenant_a
        set_a = create_permission_set(name: 'Set A')

        ActsAsTenant.test_tenant = @tenant_b
        set_b = create_permission_set(name: 'Set B')

        ActsAsTenant.test_tenant = @tenant_a
        assert_includes PermissionForge::PermissionSet.all, set_a
        assert_not_includes PermissionForge::PermissionSet.all, set_b

        ActsAsTenant.test_tenant = @tenant_b
        assert_includes PermissionForge::PermissionSet.all, set_b
        assert_not_includes PermissionForge::PermissionSet.all, set_a
      end

      test 'resources are scoped to current tenant' do
        ActsAsTenant.test_tenant = @tenant_a
        ps_a = create_permission_set(name: 'Set A')
        res_a = create_resource(permission_set: ps_a, name: 'Customer')

        ActsAsTenant.test_tenant = @tenant_b
        ps_b = create_permission_set(name: 'Set B')
        create_resource(permission_set: ps_b, name: 'Customer')

        ActsAsTenant.test_tenant = @tenant_a
        assert_equal 1, PermissionForge::Resource.count
        assert_equal res_a, PermissionForge::Resource.first
      end

      test 'permission set users are scoped to current tenant' do
        user = create_user

        ActsAsTenant.test_tenant = @tenant_a
        ps_a = create_permission_set(name: 'Set A')
        psu_a = create_permission_set_user(user: user, permission_set: ps_a)

        ActsAsTenant.test_tenant = @tenant_b
        ps_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: user, permission_set: ps_b)

        ActsAsTenant.test_tenant = @tenant_a
        assert_equal 1, PermissionForge::PermissionSetUser.count
        assert_equal psu_a, PermissionForge::PermissionSetUser.first
      end

      # --- Cache key includes tenant ---

      test 'cache key includes tenant ID when tenant is active' do
        user = create_user
        ActsAsTenant.test_tenant = @tenant_a

        key = user.send(:permission_cache_key)
        assert_match(/tenant_#{@tenant_a.id}_user_#{user.id}/, key)
      end

      test 'cache key is user-only when no tenant is set' do
        disable_tenant!
        user = create_user

        key = user.send(:permission_cache_key)
        assert_equal "#{PermissionForge::Cache::UserKeys::ENTRY_NAMESPACE}:user_#{user.id}", key
      end

      # --- Permission regeneration is tenant-scoped ---

      test 'regenerate_permissions only includes current tenant sets' do
        user = create_user

        ActsAsTenant.test_tenant = @tenant_a
        ps_a = create_permission_set(name: 'Tenant A Set')
        create_permission_set_user(user: user, permission_set: ps_a)
        create_resource(permission_set: ps_a, name: 'Customer', read_access: true)

        ActsAsTenant.test_tenant = @tenant_b
        ps_b = create_permission_set(name: 'Tenant B Set')
        create_permission_set_user(user: user, permission_set: ps_b)
        create_resource(permission_set: ps_b, name: 'Supplier', read_access: true)

        # Regenerate as tenant A
        ActsAsTenant.test_tenant = @tenant_a
        user.regenerate_permissions

        assert user.can_read?(:Customer), 'should have Customer from tenant A'
        assert_not user.can_read?(:Supplier), 'should NOT have Supplier from tenant B'
      end

      # --- Cross-tenant isolation via permission hash ---

      test 'different tenants produce different permission hashes for same user' do
        user = create_user

        ActsAsTenant.test_tenant = @tenant_a
        ps_a = create_permission_set(name: 'Set A')
        create_permission_set_user(user: user, permission_set: ps_a)
        create_resource(permission_set: ps_a, name: 'Customer', read_access: true, delete_access: true)
        user.regenerate_permissions
        hash_a = user.permissions_hash

        ActsAsTenant.test_tenant = @tenant_b
        ps_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: user, permission_set: ps_b)
        create_resource(permission_set: ps_b, name: 'Customer', read_access: true, delete_access: false)
        user.regenerate_permissions
        hash_b = user.permissions_hash

        # Different cache keys mean different hashes
        perms_a = hash_a.dig(:permissions, :resources, :Customer, :permissions)
        perms_b = hash_b.dig(:permissions, :resources, :Customer, :permissions)

        assert perms_a[:delete_access], 'tenant A should have delete'
        assert_not perms_b[:delete_access], 'tenant B should NOT have delete'
      end

      # --- Cross-tenant user sharing ---

      test 'same user can have different permissions in different tenants' do
        user = create_user

        ActsAsTenant.test_tenant = @tenant_a
        ps_a = create_permission_set(name: 'Tenant A Set')
        create_permission_set_user(user: user, permission_set: ps_a)
        create_resource(permission_set: ps_a, name: 'Customer', read_access: true)

        ActsAsTenant.test_tenant = @tenant_b
        ps_b = create_permission_set(name: 'Tenant B Set')
        create_permission_set_user(user: user, permission_set: ps_b)
        create_resource(permission_set: ps_b, name: 'Customer', read_access: true, delete_access: true)

        # Check tenant A permissions
        ActsAsTenant.test_tenant = @tenant_a
        user.regenerate_permissions
        assert user.can_read?(:Customer)
        assert_not user.can_delete?(:Customer), 'tenant A should not have delete'

        # Check tenant B permissions
        ActsAsTenant.test_tenant = @tenant_b
        user.regenerate_permissions
        assert user.can_read?(:Customer)
        assert user.can_delete?(:Customer), 'tenant B should have delete'
      end

      # --- Migration template generates tenant column ---

      test 'migration template includes tenant column when configured' do
        content = render_migration_with_tenant('account_id')
        assert_match(/t\.bigint\s+:account_id/, content)
      end

      test 'migration template omits tenant column when not configured' do
        content = render_migration_without_tenant
        assert_no_match(/account_id/, content)
      end

      private

      def enable_tenant!
        PermissionForge.configuration.tenant_model = 'Account'
        # Re-evaluate acts_as_tenant on models since config changed at boot
        # In tests, acts_as_tenant is already loaded and models already include HasTenantScoping
        # so we just need to set the current tenant
      end

      def disable_tenant!
        PermissionForge.configuration.tenant_model = nil
        ActsAsTenant.test_tenant = nil
      end

      def render_migration_with_tenant(column)
        render_migration_template('permission_forge_', tenant: column)
      end

      def render_migration_without_tenant
        render_migration_template('permission_forge_')
      end

      def render_migration_template(prefix, tenant: nil)
        render_install_template('migration.rb.tt', table_prefix: prefix, tenant_column: tenant)
      end
    end
  end
end
