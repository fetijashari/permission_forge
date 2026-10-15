# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Permission Set names are unique within a tenant, ignoring case (0.15):
  # what the admin's form already refused now holds for the console, seeds,
  # services and the API too. Rows that shared a name before stay valid until
  # one of them is renamed. (Two tenants may use the same name:
  # tenancy/tenant_isolation_test.rb.)
  class PermissionSetNameUniquenessTest < ActiveSupport::TestCase
    test 'a second set with the same name is refused, whatever its case' do
      create_permission_set(name: 'Sales Team')

      [['Sales Team'], ['sales team'], ['SALES TEAM']].each do |(name)|
        set = PermissionForge::PermissionSet.new(name: name, is_active: true)

        assert_not set.valid?, name
        assert_includes set.errors[:name], I18n.t('permission_forge.validations.permission_set.name_taken')
      end
    end

    test 'renaming a set to a name another set uses is refused; keeping its own name is not' do
      create_permission_set(name: 'Sales Team')
      support = create_permission_set(name: 'Support')

      assert_not support.update(name: 'sales team')
      assert support.reload.update(name: 'Support', description: 'still mine')
      assert support.update(name: 'SUPPORT')
    end

    test 'two sets that already share a name stay valid until one is renamed' do
      first = create_permission_set(name: 'Legacy')
      second = PermissionForge::PermissionSet.new(name: 'Legacy', is_active: true)
      second.save!(validate: false)

      assert second.update(description: 'edited without renaming')
      assert first.update(is_active: false)
      assert_not second.update(name: 'LEGACY ')
    end

    test 'unique_name numbers a taken name' do
      create_permission_set(name: 'Ops')
      create_permission_set(name: 'Ops 2')

      assert_equal 'Ops 3', PermissionForge::PermissionSet.unique_name('Ops')
      assert_equal 'Fresh', PermissionForge::PermissionSet.unique_name('Fresh')
    end

    test 'a clone without a name gets a numbered copy name instead of failing validation' do
      source = create_permission_set(name: 'Sales Team')

      first = PermissionForge::Services::PermissionSetCloner.call(permission_set: source, attrs: {})
      second = PermissionForge::Services::PermissionSetCloner.call(permission_set: source, attrs: {})

      copy = I18n.t('permission_forge.permission_sets.copy_name', name: 'Sales Team')
      assert_equal copy, first.name
      assert_equal "#{copy} 2", second.name
    end

    test 'a group clone gives each copied set a free name' do
      group = PermissionForge::PermissionSetGroup.create!(name: 'Customer team')
      create_permission_set(name: 'Sales Team', permission_set_group: group)

      cloned = PermissionForge::Services::PermissionSetGroupCloner.call(permission_set_group: group, attrs: { name: 'Customer team 2' })

      names = cloned.permission_sets.map(&:name)
      assert_equal [I18n.t('permission_forge.permission_sets.copy_name', name: 'Sales Team')], names
      assert_equal 2, PermissionForge::PermissionSet.where('LOWER(name) LIKE ?', 'sales team%').count
    end
  end
end
