require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # The cached permission hash is keyed per tenant. A change in one tenant
    # must retire that tenant's entry — and only that one — whether it happens
    # in a request with the tenant set or in a job with no tenant at all. The
    # maintenance services keep the same guarantee.
    class TenantCacheInvalidationTest < ActiveSupport::TestCase
      include TenancyTestHelper

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user

        within(@tenant_a) do
          @set_a = create_permission_set(name: 'A set')
          @resource_a = create_resource(permission_set: @set_a, name: 'Customer', read_access: true)
          @assignment_a = create_permission_set_user(user: @user, permission_set: @set_a)
        end
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'B set')
          @resource_b = create_resource(permission_set: @set_b, name: 'Supplier', read_access: true)
          @assignment_b = create_permission_set_user(user: @user, permission_set: @set_b)
        end

        @key_a = key_of(@user, @tenant_a)
        @key_b = key_of(@user, @tenant_b)
        warm_both_tenants
      end

      # --- keys ----------------------------------------------------------------

      test 'cache keys are distinct per tenant and tenant-agnostic without a tenant' do
        within(@tenant_a) { assert_equal @key_a, @user.permission_cache_key }
        within(@tenant_b) { assert_equal @key_b, @user.permission_cache_key }

        no_tenant!
        assert_equal key_of(@user), @user.permission_cache_key
      end

      test 'the memoized hash follows tenant switches and comes back intact' do
        hash_a = within(@tenant_a) { @user.permissions_hash }
        hash_b = within(@tenant_b) { @user.permissions_hash }

        refute_same hash_a, hash_b
        assert hash_a.dig(:permissions, :resources, :Customer)
        assert_nil hash_a.dig(:permissions, :resources, :Supplier)
        within(@tenant_a) { assert_equal hash_a, @user.permissions_hash }
      end

      # --- changes under a tenant ---------------------------------------------

      test 'a permission change in tenant A retires only the tenant A cache' do
        within(@tenant_a) { @resource_a.update!(read_access: false) }

        assert_not cached?(@key_a)
        assert cached?(@key_b), 'tenant B hash untouched'
        within(@tenant_a) { assert_not @user.can_read?(:Customer) }
        within(@tenant_b) { assert @user.can_read?(:Supplier) }
      end

      test 'revoking an assignment in tenant A does not touch tenant B' do
        within(@tenant_a) { @assignment_a.destroy! }

        assert_not cached?(@key_a)
        assert cached?(@key_b)
        within(@tenant_a) { assert_not @user.can_read?(:Customer) }
        within(@tenant_b) { assert @user.can_read?(:Supplier) }
      end

      test 'a new assignment in tenant B grants there and leaves tenant A alone' do
        newcomer = create_user(name: 'New')
        within(@tenant_a) { assert_not newcomer.can_read?(:Supplier) }
        key_a = key_of(newcomer, @tenant_a)
        assert cached?(key_a)

        within(@tenant_b) { create_permission_set_user(user: newcomer, permission_set: @set_b) }

        assert cached?(key_a), 'another tenant assignment does not retire this tenant cache'
        within(@tenant_b) { assert newcomer.can_read?(:Supplier) }
        within(@tenant_a) { assert_not newcomer.can_read?(:Supplier) }
      end

      # --- changes with no ambient tenant (jobs, console) ---------------------

      test 'a resource change made with no tenant set still retires the record tenant cache' do
        no_tenant!
        @resource_a.update!(read_access: false)

        assert_not cached?(@key_a), 'tenant id is taken from the changed record'
        assert cached?(@key_b)
      end

      test 'field, action and rule changes made with no tenant set retire their own tenant only' do
        children = within(@tenant_a) do
          [
            create_resource_field(resource: @resource_a, name: 'email'),
            create_resource_action(resource: @resource_a, is_permitted: true),
            create_permission_set_rule(permission_set: @set_a, resource: @resource_a)
          ]
        end

        children.each do |record|
          warm_both_tenants
          no_tenant!
          record.update!(is_active: false)

          assert_not cached?(@key_a), "#{record.class.name} change retires tenant A"
          assert cached?(@key_b), "#{record.class.name} change leaves tenant B"
        end
      end

      test 'an assignment destroyed from a job with no tenant retires its tenant cache' do
        no_tenant!
        PermissionForge::PermissionSetUser.find(@assignment_b.id).destroy!

        assert_not cached?(@key_b)
        assert cached?(@key_a)
      end

      test 'invalidate_permissions(tenant_id:) retires that tenant without an ambient tenant' do
        no_tenant!
        @user.invalidate_permissions(tenant_id: @tenant_b.id)

        assert_not cached?(@key_b)
        assert cached?(@key_a)
      end

      # --- maintenance services -----------------------------------------------

      test 'ExpiredAssignmentCleaner with no tenant cleans every tenant and retires each cache' do
        within(@tenant_a) { @assignment_a.update_columns(expires_at: 1.hour.ago) }
        within(@tenant_b) { @assignment_b.update_columns(expires_at: 1.hour.ago) }
        no_tenant!

        result = PermissionForge::Services::ExpiredAssignmentCleaner.call

        assert_equal 2, result[:removed]
        assert_not cached?(@key_a)
        assert_not cached?(@key_b)
        within(@tenant_a) { assert_not @user.can_read?(:Customer) }
        within(@tenant_b) { assert_not @user.can_read?(:Supplier) }
      end

      test 'ExpiredAssignmentCleaner under a tenant only cleans that tenant' do
        within(@tenant_a) { @assignment_a.update_columns(expires_at: 1.hour.ago) }
        within(@tenant_b) { @assignment_b.update_columns(expires_at: 1.hour.ago) }

        result = within(@tenant_a) { PermissionForge::Services::ExpiredAssignmentCleaner.call }

        assert_equal 1, result[:removed]
        assert_not cached?(@key_a)
        assert cached?(@key_b)
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'DataSubjectErasure with no tenant removes every tenant assignment and retires every cache' do
        no_tenant!

        result = PermissionForge::Services::DataSubjectErasure.call(user: @user)

        assert_equal 2, result[:assignments_removed]
        assert_not cached?(@key_a)
        assert_not cached?(@key_b)
        within(@tenant_a) { assert_not @user.can_read?(:Customer) }
        within(@tenant_b) { assert_not @user.can_read?(:Supplier) }
      end

      test 'DataSubjectErasure under a tenant only erases that tenant' do
        result = within(@tenant_a) { PermissionForge::Services::DataSubjectErasure.call(user: @user) }

        assert_equal 1, result[:assignments_removed]
        assert_not cached?(@key_a)
        assert cached?(@key_b)
        within(@tenant_b) { assert @user.can_read?(:Supplier) }
      end

      test 'ConsentWithdrawalHandler only revokes sets of the current tenant' do
        within(@tenant_a) { @set_a.update!(requires_session_flag: 'marketing') }
        within(@tenant_b) { @set_b.update!(requires_session_flag: 'marketing') }

        result = within(@tenant_a) do
          PermissionForge::Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing')
        end

        assert_equal 1, result[:revoked_sets]
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'BulkPermissionSetAssignment stamps the tenant and grants only there' do
        newcomer = create_user(name: 'New')

        within(@tenant_a) do
          result = PermissionForge::Services::BulkPermissionSetAssignment.call(
            permission_set: @set_a, user_ids: [newcomer.id], action: :assign
          )
          assert_equal 1, result[:assigned]
          assert_equal @tenant_a.id, @set_a.permission_set_users.find_by!(user_id: newcomer.id).account_id
          assert newcomer.can_read?(:Customer)
        end
        within(@tenant_b) { assert_not newcomer.can_read?(:Customer) }
      end

      # --- no tenant at all ---------------------------------------------------

      test 'with no tenant set the hash is the union of every tenant grant under the tenant-agnostic key' do
        no_tenant!

        assert @user.can_read?(:Customer)
        assert @user.can_read?(:Supplier)
        assert cached?(key_of(@user))
      end

      test 'ActsAsTenant require_tenant turns the tenant-less union into a hard failure' do
        ActsAsTenant.configuration.require_tenant = true
        PermissionForge.cache.clear

        within(@tenant_a) { assert @user.can_read?(:Customer) }

        no_tenant!
        assert_raises(ActsAsTenant::Errors::NoTenantSet) { @user.permissions_hash }
      ensure
        ActsAsTenant.configuration.require_tenant = false
      end

      private

      def cached?(key)
        !PermissionForge.cache.read(key).nil?
      end

      # The base entry key of `user` in `tenant` (nil: the tenant-agnostic key).
      def key_of(user, tenant = nil)
        PermissionForge::Cache::UserKeys.hash_key(user.id, tenant&.id)
      end

      def warm_both_tenants
        within(@tenant_a) { assert @user.can_read?(:Customer) }
        within(@tenant_b) { assert @user.can_read?(:Supplier) }
        assert cached?(@key_a) && cached?(@key_b), 'precondition: both tenant hashes are cached'
      end
    end
  end
end
