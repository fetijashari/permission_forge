require 'test_helper'

module PermissionForge
  class PermissionSetMutingTest < ActiveSupport::TestCase
    setup do
      @user = create_user
      @granting_set = create_permission_set(name: 'Granting Set')
      @muting_set = create_permission_set(name: 'Muting Set', is_muting: true)
    end

    # --- Model attributes ---

    test 'muting? returns true for muting permission sets' do
      assert @muting_set.muting?
    end

    test 'muting? returns false for granting permission sets' do
      assert_not @granting_set.muting?
    end

    test 'granting? returns true for granting permission sets' do
      assert @granting_set.granting?
    end

    test 'granting? returns false for muting permission sets' do
      assert_not @muting_set.granting?
    end

    test 'is_muting defaults to false' do
      ps = create_permission_set(name: 'Default Set')
      assert_not ps.is_muting
    end

    # --- Scopes ---

    test '.muting scope returns only muting permission sets' do
      sets = PermissionForge::PermissionSet.muting
      assert_includes sets, @muting_set
      assert_not_includes sets, @granting_set
    end

    test '.granting scope returns only granting permission sets' do
      sets = PermissionForge::PermissionSet.granting
      assert_includes sets, @granting_set
      assert_not_includes sets, @muting_set
    end

    # --- Deep clone preserves is_muting ---

    test 'deep_clone preserves is_muting flag' do
      resource = create_resource(permission_set: @muting_set, name: 'Customer', read_access: true)
      create_resource_field(resource: resource, name: 'name', read_access: true)

      cloned = @muting_set.deep_clone(name: 'Cloned Muting Set')
      assert cloned.is_muting, 'cloned set should preserve is_muting flag'
      assert_equal 'Cloned Muting Set', cloned.name
    end

    # --- Dependency validation skipped for muting sets ---

    test 'muting resource allows delete_access without read_access' do
      resource = create_resource(
        permission_set: @muting_set, name: 'Customer',
        read_access: false, delete_access: true
      )
      assert resource.valid?, 'delete without read should be valid on muting set'
    end

    test 'muting resource allows modify_all without view_all' do
      resource = create_resource(
        permission_set: @muting_set, name: 'Customer',
        view_all: false, modify_all: true
      )
      assert resource.valid?, 'modify_all without view_all should be valid on muting set'
    end

    test 'granting resource still requires read_access for delete_access' do
      resource = PermissionForge::Resource.new(
        uuid: SecureRandom.uuid, permission_set: @granting_set, name: 'Customer',
        read_access: false, delete_access: true, is_active: true, is_editable: true
      )
      assert_not resource.valid?, 'delete without read should be invalid on granting set'
      assert resource.errors[:delete_access].any?
    end

    test 'muting resource field allows edit_access without read_access' do
      resource = create_resource(permission_set: @muting_set, name: 'Customer')
      field = PermissionForge::ResourceField.create!(
        uuid: SecureRandom.uuid, resource: resource, name: 'email', label: 'Email',
        read_access: false, edit_access: true, is_active: true, is_editable: true
      )
      assert field.valid?, 'edit without read should be valid on muting set field'
    end

    # --- Deep clone ---

    test 'deep_clone of granting set preserves granting flag' do
      resource = create_resource(permission_set: @granting_set, name: 'Customer', read_access: true)
      create_resource_field(resource: resource, name: 'name', read_access: true)

      cloned = @granting_set.deep_clone(name: 'Cloned Granting Set')
      assert_not cloned.is_muting, 'cloned set should preserve granting flag'
    end
  end
end
