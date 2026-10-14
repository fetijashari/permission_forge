require 'test_helper'

module PermissionForge
  module Concerns
    class PermissionsRegeneratorTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'resource field change invalidates cached permissions for users' do
        @user.regenerate_permissions
        assert_not_nil PermissionForge.cache.read(@user.permission_cache_key)

        # Creating the field fires after_commit :invalidate_permissions_for_users,
        # which deletes the affected user's cached hash.
        create_resource_field(resource: @resource, name: 'email', read_access: true, edit_access: true)

        assert_nil PermissionForge.cache.read(@user.permission_cache_key)
      end

      test 'invalidation followed by read-through reflects the change' do
        @user.regenerate_permissions
        refute @user.field_permissions(:Customer, :email)

        field = create_resource_field(resource: @resource, name: 'email', read_access: true, edit_access: true)
        field.send(:invalidate_permissions_for_users)

        # Read-through rebuild picks up the new field.
        assert @user.field_permissions(:Customer, :email)
      end

      test 'skips blank users in permission set' do
        assert_nothing_raised do
          @resource.send(:invalidate_permissions_for_users)
        end
      end

      test 'invalidates deactivated users too so reactivation gets a fresh rebuild' do
        @user.regenerate_permissions
        assert_not_nil PermissionForge.cache.read(@user.permission_cache_key)
        @user.update!(deactivated: true)

        assert_nothing_raised do
          @resource.send(:invalidate_permissions_for_users)
        end

        assert_nil PermissionForge.cache.read(@user.permission_cache_key)
      end
    end
  end
end
