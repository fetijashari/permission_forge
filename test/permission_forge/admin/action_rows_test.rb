require_relative 'action_catalog_support'

module PermissionForge
  module Admin
    class ActionRowsTest < ActiveSupport::TestCase
      include ActionCatalogSupport

      setup do
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set)
      end

      def rows(resource = @resource, catalog: stub_catalog)
        ActionRows.new(resource.reload, catalog: catalog)
      end

      def effect(key, resource = @resource)
        rows(resource).row(key).effect
      end

      # --- discovery off ----------------------------------------------------------

      test 'with discovery off only configured rows are listed, and neither the routes nor other sets are read' do
        create_resource_action(resource: @resource, name: 'sync', label: nil)
        create_resource_action(resource: @resource, name: 'export', label: 'Export CSV')
        found = ActionRows.new(@resource.reload, catalog: Object.new, across: Object.new)

        assert_not found.discovery?
        assert_equal %w[export sync], found.rows.map(&:name)
        assert_equal ['Export CSV', 'Sync'], found.rows.map(&:label), 'English: Rails\' English for the key (FieldLabel.english)'
        I18n.with_locale(:sq) do
          labels = ActionRows.new(@resource.reload, catalog: Object.new, across: Object.new).rows.map(&:label)
          assert_equal ['Export CSV', 'sync'], labels, 'a row without a label is named by its key as stored'
        end
        assert_empty found.discovered_rows
        assert_empty found.suggestions
        assert(found.rows.all? { |row| row.endpoints.empty? && !row.unlinked })
      end

      # --- discovery on -----------------------------------------------------------

      test 'lists configured rows first, then controller actions without a row' do
        discovery_on!
        create_resource_action(resource: @resource, name: 'export')
        found = rows

        assert_predicate found, :discovery?
        assert_equal %w[export], found.configured_rows.map(&:name)
        assert_equal %w[archive merge], found.discovered_rows.map(&:name)
        assert_equal %w[export archive merge], found.rows.map(&:name)
        assert_equal %w[archive merge], found.suggestions
        assert_predicate found.row('export'), :configured?
        assert_not found.row(:archive).configured?
        I18n.with_locale(:sq) { assert_equal 'archive', rows.row('archive').label, 'a discovered action is named by its key as stored' }
        assert_nil found.row('nope')
      end

      test 'a row carries its endpoints and whether each controller is guarded' do
        discovery_on!
        create_resource_action(resource: @resource, name: 'export')
        found = rows
        export = found.row('export').endpoints.sole
        merge = found.row('merge').endpoints.sole

        assert_equal [['GET'], ['/stub/export'], 'pf_stub_guarded#export'], [export.verbs, export.paths, export.endpoint]
        assert_predicate export, :guarded?
        assert_equal [['POST'], ['/stub/:id/merge'], 'pf_stub_plain#create'], [merge.verbs, merge.paths, merge.endpoint]
        assert_not merge.guarded?
        assert_predicate found, :any_guarded?
        assert_not rows(catalog: stub_catalog(guarded: false)).any_guarded?
      end

      test 'a configured action that matches no controller action is flagged as not linked' do
        discovery_on!
        create_resource_action(resource: @resource, name: 'sync')
        create_resource_action(resource: @resource, name: 'export')
        found = rows

        assert found.row('sync').unlinked
        assert_empty found.row('sync').endpoints
        assert_not found.row('export').unlinked
        assert_not found.row('archive').unlinked
      end

      test 'an action a form built but has not saved is not a configured row' do
        discovery_on!
        @resource.reload.resource_actions.build(name: 'archive')
        found = ActionRows.new(@resource, catalog: stub_catalog)

        assert_empty found.configured_rows
        assert_includes found.suggestions, 'archive'
      end

      # --- effect -----------------------------------------------------------------

      test 'a granting row is permitted or not permitted' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'archive', is_permitted: false)

        assert_equal :permitted, effect('export')
        assert_equal :not_permitted, effect('archive')
      end

      test 'a muting row blocks or leaves the action unchanged' do
        muting = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_action(resource: muting, name: 'export', is_permitted: true)
        create_resource_action(resource: muting, name: 'archive', is_permitted: false)

        assert_equal :blocked, effect('export', muting)
        assert_equal :unchanged, effect('archive', muting)
      end

      test 'an action nobody manages follows unconfigured_action_strategy' do
        discovery_on!

        assert_equal :unmanaged_allowed, effect('archive')

        PermissionForge.configuration.unconfigured_action_strategy = :block
        assert_equal :unmanaged_blocked, effect('archive')

        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge.configuration.unconfigured_action_strategy = :anything_else
        end
      end

      test 'an action another set manages is not permitted here' do
        discovery_on!
        other = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: other, name: 'archive', is_permitted: true)
        row = rows.row('archive')

        assert_equal :managed_elsewhere, row.effect
        assert_equal ['Managers'], row.permitted_by.map(&:name)
      end

      test 'a muting set manages an action too' do
        discovery_on!
        muting = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_action(resource: muting, name: 'archive', is_permitted: true)
        row = rows.row('archive')

        assert_equal :managed_elsewhere, row.effect
        assert_empty row.permitted_by
      end

      test 'a row that is switched off has no effect of its own' do
        action = create_resource_action(resource: @resource, name: 'export', is_permitted: true, is_active: false)

        assert_equal :unmanaged_allowed, effect('export')

        other = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: other, name: 'export', is_permitted: false)
        assert_equal :managed_elsewhere, effect('export')

        action.update!(is_active: true)
        assert_equal :permitted, effect('export')
      end

      test 'rows of a switched-off resource or set are not in effect' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)

        @resource.update!(is_active: false)
        assert_equal :unmanaged_allowed, effect('export')

        @resource.update!(is_active: true)
        @set.update!(is_active: false)
        assert_equal :unmanaged_allowed, effect('export')
        assert_empty rows.row('export').permitted_by
      end

      test 'the other Permission Sets are read once, and only when a row is asked what it means' do
        discovery_on!
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: create_resource(permission_set: create_permission_set(name: 'Managers')), name: 'archive')
        # Loaded the way the admin controllers load it: with its set and its actions.
        loaded = @set.resources.includes(:resource_actions).find_by!(name: 'Customer')
        found = ActionRows.new(loaded, catalog: stub_catalog)

        assert_equal(0, count_sql { found.rows.map(&:label) })
        assert_equal(0, count_sql { found.row('export').effect })
        # Resources of that name, their Permission Sets, their actions.
        assert_equal(3, count_sql { found.rows.each { |row| [row.effect, row.permitted_by] } })
        assert_equal(0, count_sql { found.across_sets('archive') })
      end

      test 'across_sets lists the action in every set that has the resource' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource(permission_set: create_permission_set(name: 'Managers'))
        listed = rows.across_sets('export')

        assert_equal(['Managers', 'Sales rep'], listed.map { |row| row[:set].name })
        assert_equal([nil, 'export'], listed.map { |row| row[:action]&.name })
      end
    end

    class ActionAcrossSetsTest < ActiveSupport::TestCase
      include ActionCatalogSupport

      setup do
        @sales = create_permission_set(name: 'Sales rep')
        @managers = create_permission_set(name: 'Managers')
        @contractors = create_permission_set(name: 'Contractors', is_muting: true)
        @resources = [@sales, @managers, @contractors].to_h { |set| [set.name, create_resource(permission_set: set)] }
      end

      def across
        ActionAcrossSets.new('Customer')
      end

      test 'rows come granting sets first, then by name' do
        create_resource_action(resource: @resources['Managers'], name: 'export', is_permitted: true)
        rows = across.rows(:export)

        assert_equal(['Managers', 'Sales rep', 'Contractors'], rows.map { |row| row[:set].name })
        assert_equal(['export', nil, nil], rows.map { |row| row[:action]&.name })
        assert_equal @resources['Managers'], rows.first[:resource]
        assert_equal %i[action in_effect resource set], rows.first.keys.sort
      end

      test 'rows say whether the action counts in each set right now' do
        create_resource_action(resource: @resources['Managers'], name: 'export', is_active: false)
        create_resource_action(resource: @resources['Contractors'], name: 'export')
        in_effect = -> { across.rows('export').to_h { |row| [row[:set].name, row[:in_effect]] } }

        assert_equal({ 'Managers' => false, 'Sales rep' => true, 'Contractors' => true }, in_effect.call)

        @resources['Sales rep'].update!(is_active: false)
        @contractors.update!(is_active: false)

        assert_equal({ 'Managers' => false, 'Sales rep' => false, 'Contractors' => false }, in_effect.call)
      end

      test 'every set is loaded once, whatever is asked and for however many keys' do
        @resources.each_value { |resource| %w[export archive].each { |key| create_resource_action(resource: resource, name: key) } }
        found = across

        queries = count_sql do
          %w[export archive merge].each { |key| [found.managed?(key), found.permitting_sets(key), found.rows(key)] }
        end

        assert_equal 3, queries
      end

      test 'an action is managed once any set has a row in effect, granting or muting' do
        assert_not across.managed?('export')

        create_resource_action(resource: @resources['Contractors'], name: 'export', is_permitted: false)

        assert across.managed?(:export)
        assert_not across.managed?('archive')
        assert_empty across.permitting_sets('export')
      end

      test 'only granting sets with a permitting row in effect permit an action' do
        create_resource_action(resource: @resources['Sales rep'], name: 'export', is_permitted: true)
        create_resource_action(resource: @resources['Managers'], name: 'export', is_permitted: false)
        create_resource_action(resource: @resources['Contractors'], name: 'export', is_permitted: true)

        assert_equal ['Sales rep'], across.permitting_sets('export').map(&:name)
      end

      test 'switched-off sets, resources and rows neither manage nor permit' do
        action = create_resource_action(resource: @resources['Sales rep'], name: 'export', is_permitted: true)

        action.update!(is_active: false)
        assert_not across.managed?('export')

        action.update!(is_active: true)
        @resources['Sales rep'].update!(is_active: false)
        assert_not across.managed?('export')

        @resources['Sales rep'].update!(is_active: true)
        @sales.update!(is_active: false)
        assert_not across.managed?('export')
        assert_empty across.permitting_sets('export')
      end

      test 'agrees with the index the guard reads' do
        create_resource_action(resource: @resources['Sales rep'], name: 'export', is_permitted: false)
        create_resource_action(resource: @resources['Managers'], name: 'archive', is_active: false)

        %w[export archive merge].each do |key|
          assert_equal PermissionForge::ControllerActions::ManagedIndex.managed_action?('Customer', key), across.managed?(key), key
        end
      end
    end
  end
end
