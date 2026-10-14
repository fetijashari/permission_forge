# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # Changes to permission records take effect automatically. The mechanism is
    # lazy invalidation: a change deletes the affected users' cached hashes, and
    # the next permissions_hash read rebuilds them (read-through) in the reading
    # user's own request context. These tests assert the observable guarantee via
    # the read-through accessor rather than the raw cache entry.
    class PermissionsAutoRegenerationTest < ActiveSupport::TestCase
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

      def resources_hash
        @user.permissions_hash.dig(:permissions, :resources)
      end

      # --- Resource changes auto-regenerate ---

      test 'disabling a resource auto-regenerates cached permissions' do
        assert @user.can_read?(:Customer)

        @resource.update!(is_active: false)

        assert_nil resources_hash[:Customer]
      end

      test 'updating resource read_access auto-regenerates cached permissions' do
        assert @user.can_read?(:Customer)

        @resource.update!(read_access: false, edit_access: false, delete_access: false)

        assert_not resources_hash.dig(:Customer, :permissions, :read_access)
      end

      # --- ResourceField changes auto-regenerate ---

      test 'updating a field edit_access auto-regenerates cached permissions' do
        assert resources_hash.dig(:Customer, :fields, :name, :edit_access)

        field = @resource.resource_fields.find_by(name: 'name')
        field.update!(edit_access: false)

        assert_not resources_hash.dig(:Customer, :fields, :name, :edit_access)
      end

      test 'creating a new field auto-regenerates cached permissions' do
        assert_nil resources_hash.dig(:Customer, :fields, :phone)

        create_resource_field(resource: @resource, name: 'phone', read_access: true, edit_access: true)

        assert resources_hash.dig(:Customer, :fields, :phone, :read_access)
      end

      # --- PermissionSetRule changes auto-regenerate ---

      test 'creating a rule auto-regenerates cached permissions' do
        assert_equal 0, resources_hash.dig(:Customer, :permission_set_rules).size

        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: 'current_user',
          operator: 'equal'
        )

        assert_equal 1, resources_hash.dig(:Customer, :permission_set_rules).size
      end

      test 'destroying a rule auto-regenerates cached permissions' do
        rule = create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: 'current_user',
          operator: 'equal'
        )

        assert_equal 1, resources_hash.dig(:Customer, :permission_set_rules).size

        rule.destroy!

        assert_equal 0, resources_hash.dig(:Customer, :permission_set_rules).size
      end

      # --- ResourceAction changes auto-regenerate ---

      test 'creating an action auto-regenerates cached permissions' do
        assert_nil resources_hash.dig(:Customer, :actions, :export)

        create_resource_action(resource: @resource, name: 'export', is_permitted: true)

        assert resources_hash.dig(:Customer, :actions, :export)
      end

      test 'updating an action auto-regenerates cached permissions' do
        action = create_resource_action(resource: @resource, name: 'export', is_permitted: true)

        assert resources_hash.dig(:Customer, :actions, :export)

        action.update!(is_permitted: false)

        assert_not resources_hash.dig(:Customer, :actions, :export, :is_permitted)
      end

      # --- PermissionSet changes auto-regenerate ---

      test 'deactivating permission set auto-regenerates cached permissions' do
        assert @user.can_read?(:Customer)

        @permission_set.update!(is_active: false)

        assert_nil resources_hash[:Customer]
      end

      # --- PermissionSetGroup changes auto-regenerate ---

      test 'deactivating a group auto-regenerates cached permissions for group users' do
        group = create_permission_set_group(name: 'TestGroup', is_active: true)
        @permission_set.update_column(:permission_set_group_id, group.id)

        assert @user.can_read?(:Customer)

        group.update!(is_active: false)

        # Group deactivation invalidates, but the permission set is still active
        # so the user should still have access (group active/inactive doesn't gate permission sets)
        assert resources_hash[:Customer]
      end

      # --- Verify can_read?/can_edit? reflect changes immediately ---

      test 'can_read? reflects changes immediately after resource update' do
        assert @user.can_read?(:Customer)

        @resource.update!(is_active: false)

        assert_not @user.can_read?(:Customer)
      end
    end
  end
end
