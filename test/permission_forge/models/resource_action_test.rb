require 'test_helper'

module PermissionForge
  class ResourceActionTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    end

    test 'belongs to resource' do
      assoc = PermissionForge::ResourceAction.reflect_on_association(:resource)
      assert_equal :belongs_to, assoc.macro
    end

    test '.active returns only active resource actions' do
      active = create_resource_action(resource: @resource, name: 'export', is_active: true)
      create_resource_action(resource: @resource, name: 'sync', is_active: false)

      assert_includes PermissionForge::ResourceAction.active, active
      assert_equal 1, PermissionForge::ResourceAction.active.count
    end

    test 'creates resource action with all attributes' do
      action = create_resource_action(
        resource: @resource,
        name: 'approve',
        label: 'Approve Order',
        description: 'Approve a pending order',
        is_permitted: true
      )

      assert_equal 'approve', action.name
      assert_equal 'Approve Order', action.label
      assert action.is_permitted
    end

    test 'resource has_many resource_actions' do
      create_resource_action(resource: @resource, name: 'export')
      create_resource_action(resource: @resource, name: 'sync')

      assert_equal 2, @resource.resource_actions.count
    end

    test 'a second action with the same name on the same resource is invalid' do
      create_resource_action(resource: @resource, name: 'export')

      duplicate = PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: @resource, name: 'export')

      refute duplicate.valid?
      assert duplicate.errors[:name].present?, 'expected a uniqueness error on name'
    end

    test 'the same action name is allowed on another resource' do
      create_resource_action(resource: @resource, name: 'export')
      other = create_resource(permission_set: create_permission_set, name: 'Customer')

      assert PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: other, name: 'export').valid?
    end

    test 'renaming an action onto an existing name is invalid' do
      create_resource_action(resource: @resource, name: 'export')
      sync = create_resource_action(resource: @resource, name: 'sync')

      refute sync.update(name: 'export')
      assert sync.errors[:name].present?
    end

    # Installs that predate the unique index can hold duplicates. They must stay
    # editable, or nobody could switch the extra row off.
    test 'a duplicate that already exists can still be switched off' do
      create_resource_action(resource: @resource, name: 'export', is_permitted: true)
      duplicate = PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: @resource, name: 'export',
                                                      is_permitted: true)
      duplicate.save!(validate: false)

      assert duplicate.update(is_permitted: false, is_active: false)
    end

    test 'the uniqueness message is the engine\'s own translation in every locale' do
      create_resource_action(resource: @resource, name: 'export')

      %i[en sq mk].each do |locale|
        I18n.with_locale(locale) do
          duplicate = PermissionForge::ResourceAction.new(uuid: SecureRandom.uuid, resource: @resource, name: 'export')
          duplicate.valid?

          assert_equal [I18n.t('permission_forge.errors.admin.action_taken')], duplicate.errors[:name]
        end
      end
    end

    test 'destroying resource destroys resource_actions' do
      create_resource_action(resource: @resource, name: 'export')

      assert_difference 'PermissionForge::ResourceAction.count', -1 do
        @resource.destroy!
      end
    end
  end
end
