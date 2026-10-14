require 'test_helper'

module PermissionForge
  module Concerns
    class PermissionsCacheInvalidationTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true,
          create_access: true,
          edit_access: true,
          delete_access: true
        )
        create_resource_field(resource: @resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: @resource, name: 'email', read_access: true, edit_access: false)
        @user.regenerate_permissions
        Current.user = @user
      end

      test 'disabling a resource removes it from permissions after read-through rebuild' do
        assert @user.can_read?(:Customer)

        @resource.update!(is_active: false)

        # Change invalidated the cache; read-through rebuild reflects it.
        assert_nil @user.permissions_hash.dig(:permissions, :resources, :Customer)
      end

      test 'revoking read_access updates permissions after read-through rebuild' do
        assert @user.can_read?(:Customer)

        @resource.update!(read_access: false, edit_access: false, delete_access: false)

        assert_not @user.can_read?(:Customer)
      end

      test 'revoking edit_access on a field updates permissions after read-through rebuild' do
        assert @user.field_permissions(:Customer, :name)[:edit_access]

        field = @resource.resource_fields.find_by(name: 'name')
        field.update!(edit_access: false)

        assert_not @user.field_permissions(:Customer, :name)[:edit_access]
      end

      test 'adding a new rule updates permissions after read-through rebuild' do
        assert_equal 0, @user.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules).size

        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: 'current_user',
          operator: 'equal'
        )

        rules = @user.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules)
        assert_equal 1, rules.size
        assert_equal 'supplier_id', rules.first[:field_name]
      end

      test 'deactivating permission set stops user from accessing resource' do
        assert @user.can_read?(:Customer)

        @permission_set.update!(is_active: false)

        assert_not @user.can_read?(:Customer)
        assert_nil @user.permissions_hash.dig(:permissions, :resources, :Customer)
      end

      test 'removing a user from permission set clears their access without an explicit regenerate' do
        assert @user.can_read?(:Customer)

        psu = PermissionForge::PermissionSetUser.find_by(user: @user, permission_set: @permission_set)
        psu.destroy!

        # No manual regenerate: destroying the assignment invalidates the cache
        # via after_commit; read-through rebuild reflects the revocation.
        assert_not @user.can_read?(:Customer)
        assert_nil @user.permissions_hash.dig(:permissions, :resources, :Customer)
      end

      test 'destroying the whole permission set revokes access for all its users' do
        other = create_user(name: 'Other')
        create_permission_set_user(user: other, permission_set: @permission_set)
        other.regenerate_permissions
        assert other.can_read?(:Customer)

        @permission_set.destroy!

        # dependent: :destroy removes each assignment through callbacks, so every
        # previously-assigned user is invalidated even though the set is gone.
        assert_not @user.can_read?(:Customer)
        assert_not other.can_read?(:Customer)
      end
    end
  end
end
