require 'test_helper'

module PermissionForge
  module Admin
    class ChangeSetTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set(name: 'Sales rep')
        @res = create_resource(permission_set: @set, read_access: true, edit_access: true, delete_access: true,
                               view_all: true, modify_all: true)
        @name = create_resource_field(resource: @res, name: 'name', read_access: true, edit_access: true)
        @email = create_resource_field(resource: @res, name: 'email', read_access: true)
      end

      def change_set(params, set = @set)
        ChangeSet.new(permission_set: set, params: params)
      end

      test 'no params means no changes' do
        assert_predicate change_set({}), :empty?
      end

      test 'turning Read off cascades to Edit, Delete, View All, Modify All and Editable fields' do
        changes = change_set(resources: { @res.id.to_s => { read_access: '0' } }).apply!
        @res.reload

        assert_not @res.read_access
        assert_not @res.edit_access
        assert_not @res.delete_access
        assert_not @res.view_all
        assert_not @res.modify_all
        assert_equal 'read', FieldLevel.level_of(@name.reload, muting: false)
        cascaded = changes.select(&:cascaded)
        assert_includes cascaded.map(&:attribute), 'edit_access'
        assert(cascaded.any? { |c| c.kind == :field_level })
      end

      test 'turning Edit off removes Modify All but keeps View All' do
        change_set(resources: { @res.id.to_s => { edit_access: '0' } }).apply!
        @res.reload

        assert @res.view_all
        assert_not @res.modify_all
      end

      test 'field levels map to flags and an Editable request is downgraded without Edit' do
        @res.update!(edit_access: false, modify_all: false)
        change_set(fields: { @email.id.to_s => { level: 'edit' } }).apply!

        assert_equal 'read', FieldLevel.level_of(@email.reload, muting: false)
      end

      test 'masked level keeps the chosen strategy' do
        change_set(fields: { @email.id.to_s => { level: 'masked', mask_strategy: 'email' } }).apply!
        @email.reload

        assert @email.mask_access
        assert_equal 'email', @email.mask_strategy
      end

      test 'new fields are created for unconfigured columns' do
        change_set(new_fields: { @res.id.to_s => { 'domain' => { level: 'read' } } }).apply!

        assert @res.resource_fields.find_by(name: 'domain').read_access
      end

      test 'bulk sets selected fields, including unconfigured columns' do
        change_set(bulk: { resource_id: @res.id.to_s, keys: %w[name email domain], level: 'hidden' }).apply!

        assert_equal(%w[hidden hidden hidden],
                     %w[name email domain].map { |n| FieldLevel.level_of(@res.resource_fields.find_by(name: n), muting: false) })
      end

      test 'locked resources and fields are never changed' do
        @res.update_columns(is_editable: false)
        assert_predicate change_set(resources: { @res.id.to_s => { read_access: '0' } }), :empty?

        @res.update_columns(is_editable: true)
        @email.update_columns(is_editable: false)
        assert_predicate change_set(fields: { @email.id.to_s => { level: 'hidden' } }), :empty?
      end

      test 'muting sets skip cascades and accept muting levels' do
        mute = create_permission_set(name: 'Mute', is_muting: true)
        res = create_resource(permission_set: mute, read_access: false, edit_access: true)
        f = create_resource_field(resource: res, name: 'email', read_access: false)

        change_set({ resources: { res.id.to_s => { read_access: '0', edit_access: '1' } },
                     fields: { f.id.to_s => { level: 'hide' } } }, mute).apply!

        assert res.reload.edit_access
        assert_equal 'hide', FieldLevel.level_of(f.reload, muting: true)
      end

      test 'set header and action toggles are applied' do
        action = create_resource_action(resource: @res, is_permitted: false)
        changes = change_set(set: { name: 'Renamed', is_active: '0' },
                             actions: { action.id.to_s => { is_permitted: '1' } }).apply!

        assert_equal 'Renamed', @set.reload.name
        assert_not @set.is_active
        assert action.reload.is_permitted
        assert_equal %i[set_attr set_attr action], changes.map(&:kind)
      end

      test 'invalid records raise and nothing is saved' do
        assert_raises(ChangeSet::Invalid) do
          change_set(set: { name: 'x' * 300 }, resources: { @res.id.to_s => { read_access: '0' } }).apply!
        end
        assert @res.reload.read_access
      end
    end
  end
end
