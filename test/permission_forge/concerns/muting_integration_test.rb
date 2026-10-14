require 'test_helper'

module PermissionForge
  module Concerns
    class MutingIntegrationTest < ActiveSupport::TestCase
      setup do
        @user = create_user
      end

      # --- Full integration: regenerate_permissions with muting ---

      test 'regenerate_permissions applies muting sets via cache' do
        granting_set = create_permission_set(name: 'Full Access')
        create_permission_set_user(user: @user, permission_set: granting_set)
        resource = create_resource(
          permission_set: granting_set, name: 'Customer',
          read_access: true, create_access: true, edit_access: true, delete_access: true
        )
        create_resource_field(resource: resource, name: 'email', read_access: true, edit_access: true)
        create_resource_action(resource: resource, name: 'export', is_permitted: true)

        muting_set = create_permission_set(name: 'No Delete', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting_set)
        muting_resource = create_resource(
          permission_set: muting_set, name: 'Customer',
          read_access: false, create_access: false, edit_access: false, delete_access: true
        )
        create_resource_field(resource: muting_resource, name: 'email', read_access: false, edit_access: true)
        create_resource_action(resource: muting_resource, name: 'export', is_permitted: true)

        @user.regenerate_permissions

        assert @user.can_read?(:Customer), 'read preserved'
        assert @user.can_create?(:Customer), 'create preserved'
        assert @user.can_edit?(:Customer), 'edit preserved'
        assert_not @user.can_delete?(:Customer), 'delete muted'
        assert_not @user.can?(:export, :Customer), 'export action muted'
      end

      test 'user with only granting sets has normal permissions' do
        granting_set = create_permission_set(name: 'Full Access')
        create_permission_set_user(user: @user, permission_set: granting_set)
        create_resource(
          permission_set: granting_set, name: 'Customer',
          read_access: true, create_access: true, edit_access: true, delete_access: true
        )

        @user.regenerate_permissions

        assert @user.can_read?(:Customer)
        assert @user.can_create?(:Customer)
        assert @user.can_edit?(:Customer)
        assert @user.can_delete?(:Customer)
      end

      test 'user with only muting sets has no permissions' do
        muting_set = create_permission_set(name: 'Muting Only', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting_set)
        create_resource(
          permission_set: muting_set, name: 'Customer',
          read_access: true, create_access: true
        )

        @user.regenerate_permissions

        assert_not @user.can_read?(:Customer), 'should have no access (muting-only, nothing to mute)'
      end

      # --- Group scenario: same group, muting carve-out ---

      test 'user in group with granting + muting set has carve-out applied' do
        group = create_permission_set_group(name: 'Sales Team')

        granting_set = create_permission_set(name: 'Sales Access', permission_set_group: group)
        create_permission_set_user(user: @user, permission_set: granting_set)
        create_resource(
          permission_set: granting_set, name: 'Customer',
          read_access: true, create_access: true, edit_access: true, delete_access: true
        )

        muting_set = create_permission_set(name: 'Junior Lock', is_muting: true, permission_set_group: group)
        create_permission_set_user(user: @user, permission_set: muting_set)
        create_resource(
          permission_set: muting_set, name: 'Customer',
          read_access: false, create_access: false, edit_access: false, delete_access: true
        )

        @user.regenerate_permissions

        assert @user.can_read?(:Customer), 'junior can read'
        assert @user.can_create?(:Customer), 'junior can create'
        assert @user.can_edit?(:Customer), 'junior can edit'
        assert_not @user.can_delete?(:Customer), 'junior cannot delete (muted)'
      end

      # --- Multiple users: muting only affects user assigned to muting set ---

      test 'muting set only affects users assigned to it' do
        senior = @user
        junior = create_user(name: 'Junior User')

        granting_set = create_permission_set(name: 'CRM Access')
        create_permission_set_user(user: senior, permission_set: granting_set)
        create_permission_set_user(user: junior, permission_set: granting_set)
        create_resource(
          permission_set: granting_set, name: 'Customer',
          read_access: true, delete_access: true
        )

        muting_set = create_permission_set(name: 'No Delete', is_muting: true)
        create_permission_set_user(user: junior, permission_set: muting_set)
        create_resource(
          permission_set: muting_set, name: 'Customer',
          delete_access: true
        )

        senior.regenerate_permissions
        junior.regenerate_permissions

        assert senior.can_delete?(:Customer), 'senior can still delete (not assigned to muting set)'
        assert_not junior.can_delete?(:Customer), 'junior cannot delete (muting set applied)'
      end
    end
  end
end
