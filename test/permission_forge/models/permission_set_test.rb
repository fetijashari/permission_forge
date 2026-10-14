require 'test_helper'

module PermissionForge
  class PermissionSetTest < ActiveSupport::TestCase
    test 'has many resources association' do
      assoc = PermissionForge::PermissionSet.reflect_on_association(:resources)
      assert_equal :has_many, assoc.macro
    end

    test 'has many permission_set_rules association' do
      assoc = PermissionForge::PermissionSet.reflect_on_association(:permission_set_rules)
      assert_equal :has_many, assoc.macro
    end

    test 'has many permission_set_users association' do
      assoc = PermissionForge::PermissionSet.reflect_on_association(:permission_set_users)
      assert_equal :has_many, assoc.macro
    end

    test 'has many users through permission_set_users' do
      assoc = PermissionForge::PermissionSet.reflect_on_association(:users)
      assert_equal :has_many, assoc.macro
      assert_equal :permission_set_users, assoc.options[:through]
    end

    test 'belongs to permission_set_group optionally' do
      assoc = PermissionForge::PermissionSet.reflect_on_association(:permission_set_group)
      assert_equal :belongs_to, assoc.macro
      assert assoc.options[:optional]
    end

    test '.active returns only active records' do
      active = create_permission_set(is_active: true)
      create_permission_set(is_active: false, name: 'Inactive Set')
      assert_includes PermissionForge::PermissionSet.active, active
      assert_equal 1, PermissionForge::PermissionSet.active.count
    end

    test '#active? returns true for active permission set' do
      ps = PermissionForge::PermissionSet.new(is_active: true)
      assert ps.active?
      assert_not ps.inactive?
    end

    test '#inactive? returns true for inactive permission set' do
      ps = PermissionForge::PermissionSet.new(is_active: false)
      assert_not ps.active?
      assert ps.inactive?
    end

    test '#deep_clone duplicates permission set with resources, fields, and rules' do
      ps = create_permission_set(name: 'Original')
      resource = create_resource(permission_set: ps, name: 'Customer', read_access: true, edit_access: true)
      create_resource_field(resource: resource, name: 'name', read_access: true, edit_access: true)
      create_resource_field(resource: resource, name: 'email', read_access: true, edit_access: false)
      create_permission_set_rule(permission_set: ps, resource: resource)

      cloned = ps.deep_clone(name: 'Cloned')

      assert_not_equal ps.id, cloned.id
      assert_not_equal ps.uuid, cloned.uuid
      assert_equal 'Cloned', cloned.name
      assert_equal 1, cloned.resources.count
      assert_equal 2, cloned.resources.first.resource_fields.count
      assert_equal 1, cloned.resources.first.permission_set_rules.count
    end

    test '#deep_clone does not copy user assignments' do
      ps = create_permission_set
      user = create_user
      create_permission_set_user(user: user, permission_set: ps)

      cloned = ps.deep_clone(name: 'No Users')

      assert_equal 0, cloned.permission_set_users.count
    end

    test '#users_on_permission_set returns users even for inactive set so deactivation triggers regeneration' do
      ps = create_permission_set(is_active: false)
      user = create_user
      psu = create_permission_set_user(user: user, permission_set: ps)

      result = ps.send(:users_on_permission_set)
      assert_includes result, psu
    end

    test '#users_on_permission_set returns users for active set' do
      ps = create_permission_set(is_active: true)
      user = create_user
      psu = create_permission_set_user(user: user, permission_set: ps)

      result = ps.send(:users_on_permission_set)
      assert_includes result, psu
    end

    test '#deep_clone duplicates resource_actions' do
      ps = create_permission_set(name: 'With Actions')
      resource = create_resource(permission_set: ps, name: 'Customer')
      create_resource_action(resource: resource, name: 'export', is_permitted: true)
      create_resource_action(resource: resource, name: 'sync', is_permitted: false)

      cloned = ps.deep_clone(name: 'Cloned Actions')

      cloned_resource = cloned.resources.first
      assert_equal 2, cloned_resource.resource_actions.count
      action_names = cloned_resource.resource_actions.pluck(:name).sort
      assert_equal %w[export sync], action_names
    end
  end
end
