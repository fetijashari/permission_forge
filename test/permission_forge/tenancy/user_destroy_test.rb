require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # A host destroys a user while one tenant is ambient (a tenant admin's
    # request). The user's associations only reach that tenant's rows, so the
    # assignments and memberships in the other tenants used to stay, pointing
    # at a user that no longer exists: a new user given a reused id would
    # inherit them. They must go too, each through its callbacks (audited,
    # caches invalidated) and under its own tenant.
    class UserDestroyTest < ActiveSupport::TestCase
      include TenancyTestHelper

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user(name: 'Leaving User')
        @rows = { @tenant_a => assignments_in(@tenant_a), @tenant_b => assignments_in(@tenant_b) }
      end

      test 'destroying a user in one tenant removes their assignments and memberships in every tenant' do
        within(@tenant_a) { @user.destroy! }

        assert_empty PermissionSetUser.unscoped.where(user_id: @user.id)
        assert_empty PermissionSetGroupUser.unscoped.where(user_id: @user.id)
      end

      test 'each removal is audited in the tenant of the row, with its set' do
        within(@tenant_a) { @user.destroy! }

        assignment_b, = @rows.fetch(@tenant_b)
        revoked = AuditEvent.unscoped.where(event: 'assignment.revoked', record_id: assignment_b.id.to_s).sole
        assert_equal @tenant_b.id, revoked.account_id
        assert_equal assignment_b.permission_set.uuid, revoked.permission_set_uuid
        assert_equal @user.id.to_s, revoked.subject_user_id
      end

      # A row whose tenant column is empty (written before tenancy, or a host
      # whose tenant association is optional): no tenant to make ambient, so
      # it is destroyed with none, where its set can be found.
      test 'a row without a tenant goes too, audited with its set' do
        assignment_b, = @rows.fetch(@tenant_b)
        PermissionSetUser.unscoped.where(id: assignment_b.id).update_all(account_id: nil) # test setup only

        within(@tenant_a) { @user.destroy! }

        refute PermissionSetUser.unscoped.exists?(assignment_b.id)
        revoked = AuditEvent.unscoped.where(event: 'assignment.revoked', record_id: assignment_b.id.to_s).sole
        assert_equal assignment_b.permission_set.uuid, revoked.permission_set_uuid
      end

      test 'the ambient tenant is restored afterwards' do
        within(@tenant_a) do
          @user.destroy!

          assert_equal @tenant_a, ActsAsTenant.current_tenant
        end
      end

      test 'with no tenant ambient every row goes, as before' do
        no_tenant!
        @user.destroy!

        assert_empty PermissionSetUser.unscoped.where(user_id: @user.id)
        assert_empty PermissionSetGroupUser.unscoped.where(user_id: @user.id)
      end

      private

      def assignments_in(tenant)
        within(tenant) do
          set = create_permission_set(name: "Set of #{tenant.name}")
          group = create_permission_set_group(name: "Group of #{tenant.name}")
          [create_permission_set_user(user: @user, permission_set: set),
           PermissionSetGroupUser.create!(user: @user, permission_set_group: group)]
        end
      end
    end
  end
end
