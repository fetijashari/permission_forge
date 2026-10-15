require 'test_helper'

module PermissionForge
  module Services
    class PermissionSetClonerTest < ActiveSupport::TestCase
      test 'clones permission set with new uuid and overridden attributes' do
        ps = create_permission_set(name: 'Original')

        cloned = PermissionSetCloner.call(permission_set: ps, attrs: { name: 'Copy' })

        assert_not_equal ps.id, cloned.id
        assert_not_equal ps.uuid, cloned.uuid
        assert_equal 'Copy', cloned.name
        assert cloned.persisted?
      end

      test 'clones resources with fields, actions, and rules' do
        ps = create_permission_set(name: 'Full')
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'name', read_access: true, edit_access: true)
        create_resource_field(resource: resource, name: 'email', read_access: true, edit_access: false)
        create_resource_action(resource: resource, name: 'export', is_permitted: true)
        create_permission_set_rule(permission_set: ps, resource: resource)

        cloned = PermissionSetCloner.call(permission_set: ps, attrs: { name: 'Cloned' })

        assert_equal 1, cloned.resources.count
        cloned_resource = cloned.resources.first
        assert_equal 2, cloned_resource.resource_fields.count
        assert_equal 1, cloned_resource.resource_actions.count
        assert_equal 1, cloned_resource.permission_set_rules.count
      end

      # A table without the unique index can hold two rows for one action name.
      # They are OR-ed when permissions are built; the copy holds one row that
      # permits exactly what the pair did.
      test 'duplicate action rows are copied as the one row they amount to' do
        ps = create_permission_set(name: 'Legacy')
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        { 'export' => [[true, false], [true, true]],    # blocked + permitted           => permitted
          'sync' => [[true, false], [false, true]],     # blocked + switched-off permit => blocked
          'archive' => [[false, true], [false, false]] }.each do |name, rows|
          rows.each do |is_active, is_permitted|
            PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: resource, name: name,
                                                is_active: is_active, is_permitted: is_permitted).save!(validate: false)
          end
        end

        cloned = PermissionSetCloner.call(permission_set: ps, attrs: { name: 'Legacy copy' })
        actions = cloned.resources.first.resource_actions.index_by(&:name)

        assert_equal %w[archive export sync], actions.keys.sort
        assert_equal [true, true], [actions['export'].is_active, actions['export'].is_permitted]
        assert_equal [true, false], [actions['sync'].is_active, actions['sync'].is_permitted]
        assert_equal [false, true], [actions['archive'].is_active, actions['archive'].is_permitted]
      end

      test 'does not copy user assignments' do
        ps = create_permission_set
        user = create_user
        create_permission_set_user(user: user, permission_set: ps)

        cloned = PermissionSetCloner.call(permission_set: ps, attrs: { name: 'No Users' })

        assert_equal 0, cloned.permission_set_users.count
      end

      test 'cloned records have unique uuids' do
        ps = create_permission_set(name: 'UUID Test')
        resource = create_resource(permission_set: ps, name: 'Customer')
        create_resource_field(resource: resource, name: 'name', read_access: true)

        cloned = PermissionSetCloner.call(permission_set: ps, attrs: { name: 'UUID Clone' })

        cloned_resource = cloned.resources.first
        assert_not_equal resource.uuid, cloned_resource.uuid
        assert_not_equal resource.resource_fields.first.uuid, cloned_resource.resource_fields.first.uuid
      end

      test 'uses default empty attrs when none provided' do
        ps = create_permission_set(name: 'Default Attrs')

        cloned = PermissionSetCloner.call(permission_set: ps)

        # Names are unique per tenant: a clone without a name is a copy.
        assert_equal I18n.t('permission_forge.permission_sets.copy_name', name: 'Default Attrs'), cloned.name
        assert cloned.persisted?
      end
    end
  end
end
