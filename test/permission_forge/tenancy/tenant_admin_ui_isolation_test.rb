require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # The HTML admin shows and edits one tenant at a time: lists, person pages,
    # the home page and the assign/restore forms never reach another tenant,
    # and offboarding from the admin stays inside the admin's tenant.
    class TenantAdminUiIsolationTest < ActionDispatch::IntegrationTest
      include TenancyTestHelper

      ROOT = '/permission_forge'.freeze

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')

        within(@tenant_a) do
          @set_a = create_permission_set(name: 'Alphaset')
          @resource_a = create_resource(permission_set: @set_a, name: 'Customer')
          @assignment_a = create_permission_set_user(user: @user, permission_set: @set_a)
        end
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'Bravoset')
          @resource_b = create_resource(permission_set: @set_b, name: 'Supplier')
          @assignment_b = create_permission_set_user(user: @user, permission_set: @set_b, expires_at: 1.day.ago)
          @group_b = create_permission_set_group(name: 'Bravogroup')
        end

        # Every request below runs as tenant A.
        ActsAsTenant.test_tenant = @tenant_a
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      test 'the permission set list shows only the current tenant' do
        get pf('/permission_sets')

        assert_response :ok
        assert_includes response.body, 'Alphaset'
        assert_not_includes response.body, 'Bravoset'
      end

      test 'another tenant permission set, group and assignment are not found' do
        assert_raises(ActiveRecord::RecordNotFound) { get pf("/permission_sets/#{@set_b.id}") }
        assert_raises(ActiveRecord::RecordNotFound) { get pf("/groups/#{@group_b.id}") }
        assert_raises(ActiveRecord::RecordNotFound) { delete pf("/assignments/#{@assignment_b.id}") }

        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'the person page lists only the current tenant assignments' do
        get pf("/people/#{@user.id}")

        assert_response :ok
        assert_includes response.body, 'Alphaset'
        assert_not_includes response.body, 'Bravoset'

        get pf("/people/#{@user.id}?tab=effective")
        assert_response :ok
      end

      test 'needs-attention items on the home page are per tenant' do
        get pf('/')
        assert_response :ok

        assert_empty PermissionForge::Admin::AttentionItems.new.expired
        within(@tenant_b) do
          assert_equal [@assignment_b.id], PermissionForge::Admin::AttentionItems.new.expired.map(&:id)
        end
      end

      test 'the assign form refuses another tenant permission set' do
        post pf('/assignments'), params: { user_id: @user.id, set_ids: [@set_b.id] }

        assert_response :unprocessable_entity
        within(@tenant_b) do
          assert_equal 1, PermissionForge::PermissionSetUser.where(permission_set_id: @set_b.id).count
        end
      end

      test 'restoring a removed assignment cannot target another tenant set' do
        assert_raises(ActiveRecord::RecordNotFound) do
          post pf('/assignments/restore'), params: { permission_set_id: @set_b.id, user_id: @user.id }
        end
      end

      test 'a permission set created in the admin is stamped with the tenant, even with a name used elsewhere' do
        post pf('/permission_sets'), params: { name: 'Bravoset', type: 'granting' }

        created = PermissionForge::PermissionSet.find_by!(name: 'Bravoset')
        assert_equal @tenant_a.id, created.account_id
        assert_redirected_to pf("/permission_sets/#{created.id}")
      end

      test 'erasure from the admin only removes the admin tenant assignments' do
        post pf("/people/#{@user.id}/erasure"), params: { confirmation: 'Ana Krasniqi' }

        assert_redirected_to pf('/people')
        assert_not PermissionForge::PermissionSetUser.exists?(@assignment_a.id)
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'remove-all from the admin only removes the admin tenant assignments' do
        delete pf("/people/#{@user.id}/remove_all")

        assert_not PermissionForge::PermissionSetUser.exists?(@assignment_a.id)
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      private

      def pf(path)
        "#{ROOT}#{path}"
      end
    end
  end
end
