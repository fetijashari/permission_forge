require 'test_helper'

module PermissionForge
  module Concerns
    class PermissionedUserTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true,
          create_access: true,
          edit_access: false,
          delete_access: false
        )
        create_resource_field(
          resource: @resource,
          name: 'name',
          label: 'Name',
          read_access: true,
          edit_access: true
        )
        @user.regenerate_permissions
      end

      test '#permissions_hash returns the cached permission hash' do
        hash = @user.permissions_hash
        assert hash.key?(:profile)
        assert hash.key?(:permissions)
        assert hash[:permissions][:resources].key?(:Customer)
      end

      test '#regenerate_permissions stores permissions in the cache' do
        @user.regenerate_permissions
        cached = PermissionForge.cache.read(@user.permission_cache_key)
        assert_not_nil cached
        assert cached[:permissions][:resources][:Customer].present?
      end

      test '#regenerate_permissions includes resource-level permissions' do
        hash = @user.permissions_hash
        perms = hash.dig(:permissions, :resources, :Customer, :permissions)
        assert perms[:read_access]
        assert perms[:create_access]
        assert_not perms[:edit_access]
        assert_not perms[:delete_access]
      end

      test '#regenerate_permissions includes field-level permissions' do
        hash = @user.permissions_hash
        fields = hash.dig(:permissions, :resources, :Customer, :fields)
        assert_equal({ read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' }, fields[:name])
      end

      test '#regenerate_permissions includes source permission sets' do
        hash = @user.permissions_hash
        sources = hash.dig(:permissions, :resources, :Customer, :source_permission_sets)
        assert_equal 1, sources.size
        assert_equal @permission_set.uuid, sources.first[:uuid]
      end

      test '#can_read? returns true when user has read_access' do
        assert @user.can_read?('Customer')
      end

      test '#can_read? returns false for unknown resources' do
        assert_not @user.can_read?('UnknownModel')
      end

      test '#can_create? returns true when user has create_access' do
        assert @user.can_create?('Customer')
      end

      test '#can_edit? returns false when user lacks edit_access' do
        assert_not @user.can_edit?('Customer')
      end

      test '#can_delete? returns false when user lacks delete_access' do
        assert_not @user.can_delete?('Customer')
      end

      test '#permissions_for returns the resource-level permissions hash' do
        perms = @user.permissions_for(:Customer)
        assert perms.key?(:read_access)
        assert perms.key?(:create_access)
        assert perms.key?(:edit_access)
        assert perms.key?(:delete_access)
      end

      test '#permissions_for returns empty hash for unknown resources' do
        assert_equal({}, @user.permissions_for(:Unknown))
      end

      test '#permissions_hash_for returns the full resource entry' do
        entry = @user.permissions_hash_for(:Customer)
        assert entry.key?(:permissions)
        assert entry.key?(:fields)
        assert entry.key?(:actions)
        assert entry.key?(:source_permission_sets)
        assert entry.key?(:permission_set_rules)
      end

      test 'can_show? aliases can_read?' do
        assert_equal @user.can_read?('Customer'), @user.can_show?('Customer')
      end

      test 'can_update? aliases can_edit?' do
        assert_equal @user.can_edit?('Customer'), @user.can_update?('Customer')
      end

      test 'can_destroy? aliases can_delete?' do
        assert_equal @user.can_delete?('Customer'), @user.can_destroy?('Customer')
      end

      # --- can? generic method ---

      test '#can? delegates CRUD actions to existing helpers' do
        assert @user.can?(:read, :Customer)
        assert @user.can?(:create, :Customer)
        assert_not @user.can?(:edit, :Customer)
        assert_not @user.can?(:delete, :Customer)
      end

      test '#can? handles :update and :destroy aliases' do
        assert_not @user.can?(:update, :Customer)
        assert_not @user.can?(:destroy, :Customer)
      end

      test '#can? checks custom resource actions' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        @user.regenerate_permissions

        assert @user.can?(:export, :Customer)
      end

      test '#can? returns false for unknown custom actions' do
        assert_not @user.can?(:nonexistent, :Customer)
      end

      test '#can? returns false for unknown resources' do
        assert_not @user.can?(:read, :Unknown)
      end

      test '#can? returns false for denied custom actions' do
        create_resource_action(resource: @resource, name: 'sync', is_permitted: false)
        @user.regenerate_permissions

        assert_not @user.can?(:sync, :Customer)
      end

      # --- Masked field helpers ---

      test '#masked_field? returns true for masked fields' do
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'email'
        )
        @user.regenerate_permissions

        assert @user.masked_field?(:Customer, :email)
      end

      test '#masked_field? returns false for non-masked fields' do
        assert_not @user.masked_field?(:Customer, :name)
      end

      test '#masked_field? returns nil-safe for unknown fields' do
        assert_not @user.masked_field?(:Customer, :nonexistent)
      end

      test '#mask_strategy_for returns the strategy' do
        create_resource_field(
          resource: @resource, name: 'phone', label: 'Phone',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'last4'
        )
        @user.regenerate_permissions

        assert_equal 'last4', @user.mask_strategy_for(:Customer, :phone)
      end

      test '#mask_strategy_for defaults to full for unknown fields' do
        assert_equal 'full', @user.mask_strategy_for(:Customer, :nonexistent)
      end

      test '#field_permissions returns field permission hash' do
        perms = @user.field_permissions(:Customer, :name)
        assert perms[:read_access]
        assert perms[:edit_access]
      end

      test '#field_permissions returns nil for unknown resource' do
        assert_nil @user.field_permissions(:Unknown, :name)
      end

      # --- Multi-permission-set merging (most permissive wins) ---

      test 'multi-set: can_read? returns true when one set grants and another denies' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, edit_access: true)
        @user.regenerate_permissions

        assert @user.can_read?('Customer'), 'should have read from first set'
        assert @user.can_edit?('Customer'), 'should have edit from second set'
      end

      test 'multi-set: masked_field? returns false when one set unmasks' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer', read_access: true)
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: res_b, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: false, mask_strategy: 'full'
        )
        @user.regenerate_permissions

        assert_not @user.masked_field?(:Customer, :email), 'should be unmasked (FALSE wins)'
      end

      test 'multi-set: can? returns true for custom action when one set permits' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        res_b = create_resource(permission_set: set_b, name: 'Customer', read_access: true)
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        create_resource_action(resource: res_b, name: 'export', is_permitted: true)
        @user.regenerate_permissions

        assert @user.can?(:export, :Customer), 'should be permitted (TRUE wins)'
      end

      test 'multi-set: three sets with mixed permissions resolve to most permissive' do
        set_b = create_permission_set(name: 'Set B')
        set_c = create_permission_set(name: 'Set C')
        create_permission_set_user(user: @user, permission_set: set_b)
        create_permission_set_user(user: @user, permission_set: set_c)
        # Set A: read only (from setup)
        # Set B: delete only
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, delete_access: true)
        # Set C: edit only
        create_resource(permission_set: set_c, name: 'Customer', read_access: true, edit_access: true)
        @user.regenerate_permissions

        assert @user.can_read?('Customer'), 'read from Set A'
        assert @user.can_create?('Customer'), 'create from Set A'
        assert @user.can_edit?('Customer'), 'edit from Set C'
        assert @user.can_delete?('Customer'), 'delete from Set B'
      end

      # --- ViewAll / ModifyAll ---

      test '#can_view_all? returns true when view_all is enabled' do
        @resource.update!(view_all: true)
        @user.regenerate_permissions
        assert @user.can_view_all?('Customer')
      end

      test '#can_view_all? returns false when view_all is disabled' do
        assert_not @user.can_view_all?('Customer')
      end

      test '#can_modify_all? returns true when modify_all is enabled' do
        @resource.update!(view_all: true, modify_all: true)
        @user.regenerate_permissions
        assert @user.can_modify_all?('Customer')
      end

      test '#can_modify_all? returns false when modify_all is disabled' do
        assert_not @user.can_modify_all?('Customer')
      end

      test 'multi-set: TRUE wins for view_all' do
        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b)
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, view_all: true)
        @user.regenerate_permissions

        assert @user.can_view_all?('Customer'), 'view_all should be true (TRUE wins)'
      end
    end
  end
end
