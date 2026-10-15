require 'test_helper'

module PermissionForge
  class ResourceTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
    end

    test 'belongs to permission_set' do
      assoc = PermissionForge::Resource.reflect_on_association(:permission_set)
      assert_equal :belongs_to, assoc.macro
    end

    test 'has many resource_fields' do
      assoc = PermissionForge::Resource.reflect_on_association(:resource_fields)
      assert_equal :has_many, assoc.macro
    end

    test 'has many permission_set_rules' do
      assoc = PermissionForge::Resource.reflect_on_association(:permission_set_rules)
      assert_equal :has_many, assoc.macro
    end

    test '.active returns only active resources' do
      active = create_resource(permission_set: @permission_set, is_active: true)
      create_resource(permission_set: @permission_set, is_active: false, name: 'Inactive')
      assert_includes PermissionForge::Resource.active, active
      assert_equal 1, PermissionForge::Resource.active.count
    end

    test '.grant_full_access! creates resource with full CRUD and generates fields' do
      resource = PermissionForge::Resource.grant_full_access!(
        permission_set: @permission_set,
        resource_name: 'Customer'
      )

      assert resource.read_access
      assert resource.create_access
      assert resource.edit_access
      assert resource.delete_access
      assert resource.is_active
      assert resource.resource_fields.any?
      assert resource.resource_fields.all?(&:read_access)
      assert resource.resource_fields.reject { |field| %w[created_at updated_at].include?(field.name) }.all?(&:edit_access)
      assert_not resource.resource_fields.find_by!(name: 'created_at').edit_access, 'timestamps are read-only'
    end

    # --- Permission dependency validation ---

    test 'edit_access requires read_access' do
      resource = PermissionForge::Resource.new(
        uuid: SecureRandom.uuid, permission_set: @permission_set,
        name: 'Test', read_access: false, edit_access: true
      )
      assert_not resource.valid?
      assert_includes resource.errors[:edit_access], 'requires read_access to be enabled'
    end

    test 'delete_access requires read_access' do
      resource = PermissionForge::Resource.new(
        uuid: SecureRandom.uuid, permission_set: @permission_set,
        name: 'Test', read_access: false, delete_access: true
      )
      assert_not resource.valid?
      assert_includes resource.errors[:delete_access], 'requires read_access to be enabled'
    end

    test 'modify_all requires view_all' do
      resource = PermissionForge::Resource.new(
        uuid: SecureRandom.uuid, permission_set: @permission_set,
        name: 'Test', read_access: true, view_all: false, modify_all: true
      )
      assert_not resource.valid?
      assert_includes resource.errors[:modify_all], 'requires view_all to be enabled'
    end

    test 'valid when edit_access true and read_access true' do
      resource = create_resource(permission_set: @permission_set, read_access: true, edit_access: true)
      assert resource.valid?
    end

    test 'valid when all access false' do
      resource = create_resource(
        permission_set: @permission_set,
        read_access: false, create_access: false, edit_access: false, delete_access: false
      )
      assert resource.valid?
    end

    test 'valid when view_all and modify_all both true' do
      resource = create_resource(
        permission_set: @permission_set,
        read_access: true, view_all: true, modify_all: true
      )
      assert resource.valid?
    end

    # --- ViewAll / ModifyAll defaults ---

    test 'view_all defaults to false' do
      resource = create_resource(permission_set: @permission_set)
      assert_not resource.view_all
    end

    test 'modify_all defaults to false' do
      resource = create_resource(permission_set: @permission_set)
      assert_not resource.modify_all
    end
  end
end
