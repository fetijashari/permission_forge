require 'test_helper'

module PermissionForge
  module Services
    class PermissionSetGroupClonerTest < ActiveSupport::TestCase
      test 'clones group with new uuid and overridden attributes' do
        group = create_permission_set_group(name: 'Original Group')

        cloned = PermissionSetGroupCloner.call(permission_set_group: group, attrs: { name: 'Copy Group' })

        assert_not_equal group.id, cloned.id
        assert_not_equal group.uuid, cloned.uuid
        assert_equal 'Copy Group', cloned.name
        assert cloned.persisted?
      end

      test 'clones all permission sets within the group' do
        group = create_permission_set_group(name: 'With Sets')
        ps1 = create_permission_set(name: 'Set 1', permission_set_group: group)
        ps2 = create_permission_set(name: 'Set 2', permission_set_group: group)
        create_resource(permission_set: ps1, name: 'Customer')
        create_resource(permission_set: ps2, name: 'Order')

        cloned = PermissionSetGroupCloner.call(permission_set_group: group, attrs: { name: 'Cloned Group' })

        cloned_sets = PermissionForge::PermissionSet.where(permission_set_group: cloned)
        assert_equal 2, cloned_sets.count
        assert_equal 1, cloned_sets.find_by(name: I18n.t('permission_forge.permission_sets.copy_name', name: 'Set 1')).resources.count
        assert_equal 1, cloned_sets.find_by(name: I18n.t('permission_forge.permission_sets.copy_name', name: 'Set 2')).resources.count
      end

      test 'does not copy user assignments' do
        group = create_permission_set_group(name: 'Users Group')
        user = create_user
        PermissionForge::PermissionSetGroupUser.create!(permission_set_group: group, user: user)

        cloned = PermissionSetGroupCloner.call(permission_set_group: group, attrs: { name: 'No Users' })

        assert_equal 0, cloned.permission_set_group_users.count
      end

      test 'uses default empty attrs when none provided' do
        group = create_permission_set_group(name: 'Default')

        cloned = PermissionSetGroupCloner.call(permission_set_group: group)

        assert_equal 'Default', cloned.name
        assert cloned.persisted?
      end
    end
  end
end
