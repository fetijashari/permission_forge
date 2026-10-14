require_relative 'action_catalog_support'

module PermissionForge
  module Admin
    # ChangeSetParts::NewActions — discovered controller actions added to a set.
    class ChangeSetNewActionsTest < ActiveSupport::TestCase
      include ActionCatalogSupport

      FakeCatalog = Struct.new(:keys) do
        def keys_for(_resource_name) = keys
      end

      setup do
        discovery_on!
        @set = create_permission_set(name: 'Sales rep')
        @res = create_resource(permission_set: @set)
        @catalog = stub_catalog
      end

      def change_set(params, set: @set, catalog: @catalog)
        ChangeSet.new(permission_set: set, params: params, catalog: catalog)
      end

      def pick(keys, resource = @res)
        { new_actions: { resource.id.to_s => keys } }
      end

      def names(resource = @res)
        resource.resource_actions.reload.map(&:name).sort
      end

      test 'creates a row for each picked controller action' do
        changes = change_set(pick('export' => { is_permitted: '1' }, 'archive' => { is_permitted: '0' })).apply!
        export = @res.resource_actions.find_by(name: 'export')
        archive = @res.resource_actions.find_by(name: 'archive')

        assert_equal %i[new_action new_action], changes.map(&:kind)
        assert_equal [nil, true], [changes.first.from, changes.first.to]
        assert_equal @res.id, changes.first.resource.id
        assert export.is_permitted
        assert export.is_active
        assert_equal 'Export', export.label
        assert_not archive.is_permitted
      end

      test 'a blank choice adds nothing, and the routes are not read' do
        params = pick('export' => { is_permitted: '' }, 'archive' => {})
                 .merge(bulk_actions: { resource_id: @res.id.to_s, is_permitted: ' ' })

        assert_predicate change_set(params, catalog: Object.new), :empty?
      end

      test 'only keys the catalog lists for the resource are created' do
        change_set(pick('export' => { is_permitted: '1' }, 'delete_everything' => { is_permitted: '1' })).apply!

        assert_equal %w[export], names
      end

      test 'a listed key outside the action key format is not created' do
        catalog = FakeCatalog.new(%w[Bad-Key export])
        change_set(pick('Bad-Key' => { is_permitted: '1' }, 'export' => { is_permitted: '1' }), catalog: catalog).apply!

        assert_equal %w[export], names
      end

      test 'keys of another resource are not created' do
        supplier = create_resource(permission_set: @set, name: 'Supplier')

        assert_predicate change_set(pick({ 'export' => { is_permitted: '1' } }, supplier)), :empty?
      end

      test 'an action that already has a row is skipped' do
        create_resource_action(resource: @res, name: 'export', is_permitted: false)

        assert_predicate change_set(pick('export' => { is_permitted: '1' })), :empty?
        assert_not @res.resource_actions.find_by(name: 'export').is_permitted
      end

      test 'locked resources and locked sets are skipped' do
        @res.update_columns(is_editable: false)
        assert_predicate change_set(pick('export' => { is_permitted: '1' })), :empty?

        @res.update_columns(is_editable: true)
        @set.update_columns(is_editable: false)
        assert_predicate change_set(pick('export' => { is_permitted: '1' }), set: @set.reload), :empty?
        assert_predicate change_set({ bulk_actions: { resource_id: @res.id.to_s, is_permitted: '1' } }, set: @set), :empty?
        assert_empty names
      end

      test 'a resource of another set is ignored' do
        other = create_resource(permission_set: create_permission_set(name: 'Managers'))

        assert_predicate change_set(pick({ 'export' => { is_permitted: '1' } }, other)), :empty?
      end

      test 'nothing is created while discovery is off, and the routes are not read' do
        PermissionForge.configuration.controller_action_discovery = false

        assert_predicate change_set(pick('export' => { is_permitted: '1' }), catalog: Object.new), :empty?
      end

      test 'bulk adds every discovered action without a row' do
        create_resource_action(resource: @res, name: 'export')
        changes = change_set({ bulk_actions: { resource_id: @res.id.to_s, is_permitted: '1' } }).apply!

        assert_equal(%w[archive merge], changes.map { |change| change.record.name })
        assert_equal %w[archive export merge], names
        assert(@res.resource_actions.where(name: %w[archive merge]).all?(&:is_permitted))
      end

      test 'a row choice wins over the bulk choice, and a blank row choice does not opt out' do
        params = pick('archive' => { is_permitted: '0' }, 'merge' => { is_permitted: '' })
                 .merge(bulk_actions: { resource_id: @res.id.to_s, is_permitted: '1' })
        change_set(params).apply!

        assert_equal %w[archive export merge], names
        assert_not @res.resource_actions.find_by(name: 'archive').is_permitted
        assert @res.resource_actions.find_by(name: 'merge').is_permitted
      end

      test 'a blank bulk choice and malformed input add nothing' do
        assert_predicate change_set({ bulk_actions: { resource_id: @res.id.to_s, is_permitted: '' } }), :empty?
        assert_predicate change_set({ bulk_actions: 'junk', new_actions: { @res.id.to_s => 'junk' } }), :empty?
        assert_predicate change_set({ bulk_actions: %w[a b], new_actions: { @res.id.to_s => { 'export' => 'junk' } } }), :empty?
        assert_predicate change_set({ new_actions: 'junk' }), :empty?
      end

      test 'in a muting set a new row blocks the action' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        resource = create_resource(permission_set: muting)
        changes = change_set(pick({ 'export' => { is_permitted: '1' } }, resource), set: muting).apply!

        assert_equal [true], changes.map(&:to)
        assert resource.resource_actions.find_by(name: 'export').is_permitted
      end

      test 'the first row makes the action managed' do
        index = PermissionForge::ControllerActions::ManagedIndex

        assert_not index.managed_action?('Customer', 'archive')

        change_set(pick('archive' => { is_permitted: '0' })).apply!

        assert index.managed_action?('Customer', 'archive')
      end

      test 'new actions are saved together with the other edits' do
        action = create_resource_action(resource: @res, name: 'export', is_permitted: false)
        params = pick('archive' => { is_permitted: '1' })
                 .merge(actions: { action.id.to_s => { is_permitted: '1' } }, resources: { @res.id.to_s => { create_access: '1' } })
        changes = change_set(params).apply!

        assert_equal %i[resource_flag action new_action], changes.map(&:kind)
        assert action.reload.is_permitted
        assert @res.reload.create_access
        assert_equal %w[archive export], names
      end

      test 'the catalog is built from the routes when none is injected' do
        PermissionForge.configuration.controller_action_resolver = nil
        change_set(pick('export' => { is_permitted: '1' }, 'no_such_action' => { is_permitted: '1' }), catalog: nil).apply!

        assert_equal %w[export], names
      end
    end
  end
end
