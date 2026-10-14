require 'test_helper'

module PermissionForge
  class ResourceFieldTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set)
    end

    # The name check must compare the way the column's collation does, which
    # is the way the unique index does. A forced case-sensitive check lets
    # "Email" through beside "email" on MySQL's default collation and the
    # index then raises RecordNotUnique.
    test 'name uniqueness leaves case sensitivity to the collation' do
      validator = PermissionForge::ResourceField.validators_on(:name)
                                                .grep(ActiveRecord::Validations::UniquenessValidator).first

      assert_equal [:resource_id], Array(validator.options[:scope])
      refute validator.options.key?(:case_sensitive)
    end

    test 'belongs to resource' do
      assoc = PermissionForge::ResourceField.reflect_on_association(:resource)
      assert_equal :belongs_to, assoc.macro
    end

    test '.active returns only active fields' do
      active = create_resource_field(resource: @resource, is_active: true, name: 'active_field')
      create_resource_field(resource: @resource, is_active: false, name: 'inactive_field')
      assert_includes PermissionForge::ResourceField.active, active
      assert_equal 1, PermissionForge::ResourceField.active.count
    end

    # --- Permission dependency validation ---

    test 'edit_access requires read_access' do
      field = PermissionForge::ResourceField.new(
        uuid: SecureRandom.uuid, resource: @resource,
        name: 'test', label: 'Test', read_access: false, edit_access: true
      )
      assert_not field.valid?
      assert_includes field.errors[:edit_access], 'requires read_access to be enabled'
    end

    test 'mask_access requires read_access' do
      field = PermissionForge::ResourceField.new(
        uuid: SecureRandom.uuid, resource: @resource,
        name: 'test', label: 'Test', read_access: false, mask_access: true
      )
      assert_not field.valid?
      assert_includes field.errors[:mask_access], 'requires read_access to be enabled'
    end

    test 'valid when edit_access true and read_access true' do
      field = create_resource_field(resource: @resource, name: 'valid_field', read_access: true, edit_access: true)
      assert field.valid?
    end

    test 'valid when mask_access true and read_access true' do
      field = create_resource_field(
        resource: @resource, name: 'masked_field',
        read_access: true, mask_access: true, mask_strategy: 'full'
      )
      assert field.valid?
    end
  end
end
