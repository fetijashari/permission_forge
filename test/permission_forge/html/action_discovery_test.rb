require_relative 'admin_test_case'
require_relative '../admin/action_catalog_support'

module PermissionForge
  module Html
    # The Actions tab and the action drawers, with controller_action_discovery
    # off (today's behaviour) and on (endpoints, guard status, effect, adding
    # discovered actions through review → apply).
    class ActionDiscoveryTest < AdminTestCase
      include PermissionForge::Admin::ActionCatalogSupport

      setup do
        @export = create_resource_action(resource: @resource, name: 'export', label: 'Export', is_permitted: true)
        @base = "/permission_sets/#{@set.id}/resources/Customer"
      end

      # Runs the block with discovery on and the stub catalog: export + archive
      # on a guarded controller, merge on an unguarded one.
      def discovering(guarded: true, &)
        discovery_on!
        with_catalog(stub_catalog(guarded: guarded), &)
      end

      def assert_clean_markup(path)
        body = response.body
        assert_no_match(/\sstyle="/, body, "inline style on #{path}")
        assert_no_match(/<script(?![^>]*\ssrc=)/, body, "inline script on #{path}")
        assert_no_match(/\son[a-z]+="/, body, "inline handler on #{path}")
        classes = body.scan(/class="([^"]*)"/).flatten.flat_map(&:split).uniq
        assert_empty classes.reject { |c| c.start_with?('pf-') }, "unprefixed classes on #{path}"
      end

      def new_action_params(keys)
        { pf: { new_actions: { @resource.id => keys } } }
      end

      # Stands in for Admin::ActionAcrossSets and reads nothing.
      NullAcross = Struct.new(:resource_name) do
        def managed?(_key) = false
        def permitting_sets(_key) = []
        def rows(_key) = []
      end

      # Runs the block with every ActionAcrossSets.new answering a NullAcross.
      def with_null_across
        across = PermissionForge::Admin::ActionAcrossSets
        across.define_singleton_method(:new) { |name| NullAcross.new(name) }
        yield
      ensure
        across.singleton_class.send(:remove_method, :new)
      end

      # --- discovery off ----------------------------------------------------------

      test 'with discovery off the tab lists configured actions and nothing else' do
        get pf("#{@base}?tab=actions")

        assert_response :success
        assert_select '.pf-card__row', count: 1
        assert_select '.pf-card__row code.pf-mono-key', text: 'export'
        assert_select "input[type=checkbox][name='pf[actions][#{@export.id}][is_permitted]'][checked]"
        assert_select 'select', count: 0
        assert_select '.pf-banner--warn', count: 0
        assert_no_match(/new_actions|bulk_actions/, response.body)
        assert_no_match I18n.t('permission_forge.resource_actions.effect.right_now'), response.body
        assert_no_match I18n.t('permission_forge.resource_actions.managed_note.title'), response.body
        assert_no_match I18n.t('permission_forge.resources.actions_tab.unlinked'), response.body
      end

      test 'with discovery off the drawers offer no suggestions and show no endpoints' do
        get pf("#{@base}/actions/new?key=archive")
        assert_response :success
        assert_select 'datalist', count: 0
        assert_select 'input#pf-action-name[value=archive]'
        assert_no_match I18n.t('permission_forge.resource_actions.managed_note.title'), response.body

        get pf("#{@base}/actions/#{@export.id}")
        assert_response :success
        assert_no_match I18n.t('permission_forge.resource_actions.show.where'), response.body
        assert_select '.pf-listbox .pf-option', count: 1
      end

      test 'with discovery off a posted new action is ignored' do
        post pf("#{@base}/review"), params: new_action_params('archive' => { is_permitted: '1' })

        assert_redirected_to pf(@base)
        assert_equal I18n.t('permission_forge.flash.permission_sets.no_changes'), flash[:notice]
      end

      # The badge texts are the ones the drawer rendered before controller-action
      # discovery existed (glyphs included); granting sets come first, then by name.
      test 'the action drawer words the action in every Permission Set as it did before discovery' do
        { 'Managers' => [false, false], 'Contractors' => [true, true], 'Interns' => [true, false] }.each do |name, (muting, flag)|
          resource = create_resource(permission_set: create_permission_set(name: name, is_muting: muting))
          create_resource_action(resource: resource, name: 'export', is_permitted: flag)
        end
        create_resource(permission_set: create_permission_set(name: 'Guests'))

        get pf("#{@base}/actions/#{@export.id}")

        assert_equal ['Guests', 'Managers', 'Sales rep', 'Contractors', 'Interns'],
                     css_select('.pf-listbox .pf-option .pf-fw-600').map(&:text)
        assert_equal ['– Not configured', '– Not permitted', '✎ ✓ Permitted', '⊘ ⊘ Blocked', '– Unchanged'],
                     css_select('.pf-listbox .pf-option .pf-level-badge').map(&:text)
        assert_select '.pf-listbox .pf-badge--off', count: 0
      end

      test 'the action drawer marks the sets where the action does not count right now' do
        off_set = create_resource(permission_set: create_permission_set(name: 'Old set', is_active: false))
        create_resource_action(resource: off_set, name: 'export', is_permitted: true)
        off_row = create_resource(permission_set: create_permission_set(name: 'Row off'))
        create_resource_action(resource: off_row, name: 'export', is_permitted: true, is_active: false)
        create_resource(permission_set: create_permission_set(name: 'Resource off'), is_active: false)
        create_resource(permission_set: create_permission_set(name: 'No row'))

        get pf("#{@base}/actions/#{@export.id}")

        off = css_select('.pf-listbox .pf-option').select { |option| option.css('.pf-badge--off').any? }
        assert_equal(['Old set', 'Resource off', 'Row off'], off.map { |option| option.at_css('.pf-fw-600').text })
      end

      # The tab shows nothing about other Permission Sets while discovery is off,
      # so it must not read them: the same request with ActionRows' across-sets
      # data replaced by an object that reads nothing may not be cheaper.
      test 'with discovery off the tab runs no queries for the action across Permission Sets' do
        2.times do |index|
          other = create_resource(permission_set: create_permission_set(name: "Other #{index}"))
          create_resource_action(resource: other, name: 'export', is_permitted: true)
        end
        path = pf("#{@base}?tab=actions")
        get path # warm caches

        with_across = count_sql { get path }
        without_across = with_null_across { count_sql { get path } }

        assert_response :success
        assert_select '.pf-card__row', count: 1
        assert_operator with_across, :<=, without_across
      end

      test 'with discovery on the tab reads the other Permission Sets once, however many actions it lists' do
        create_resource_action(resource: @resource, name: 'sync')
        path = pf("#{@base}?tab=actions")
        discovering do
          get path # warm caches
          with_across = count_sql { get path }
          without_across = with_null_across { count_sql { get path } }

          # Resources of that name, their Permission Sets, their actions.
          assert_equal 3, with_across - without_across
        end
      end

      # --- the count on the Actions tab -------------------------------------------

      def assert_actions_tab_count(count)
        assert_select 'a.pf-tab', text: "#{I18n.t('permission_forge.ui.actions')} (#{count})", count: 1
      end

      test 'the Actions tab counts the rows it shows: configured actions, plus discovered ones with discovery on' do
        create_resource_action(resource: @resource, name: 'sync')

        get pf("#{@base}?tab=actions")
        assert_select '.pf-card__row', count: 2
        assert_actions_tab_count(2)

        discovering do
          get pf("#{@base}?tab=actions")
          assert_select '.pf-card__row', count: 4
          assert_actions_tab_count(4)

          get pf(@base) # the Fields tab shows the same number
          assert_actions_tab_count(4)
        end
      end

      # --- discovery on: the tab --------------------------------------------------

      test 'the tab shows endpoints, guard status and effect for every action' do
        discovering do
          get pf("#{@base}?tab=actions")

          assert_response :success
          assert_select '.pf-card__row', count: 3
          assert_match 'GET /stub/export', response.body
          assert_match 'pf_stub_guarded#export', response.body
          assert_match 'POST /stub/:id/merge', response.body
          assert_match 'pf_stub_plain#create', response.body
          assert_select '.pf-badge--grant', text: /✓ #{I18n.t('permission_forge.resource_actions.endpoints.guarded')}/, count: 2
          assert_select '.pf-badge--warn', text: /⚠ #{I18n.t('permission_forge.resource_actions.endpoints.not_guarded')}/, count: 1
          assert_select '.pf-badge--grant', text: /✓ #{I18n.t('permission_forge.resource_actions.states.permitted')}/, count: 1
          assert_select '.pf-badge--unconfigured',
                        text: /○ #{I18n.t('permission_forge.resource_actions.effect.unmanaged_allowed')}/, count: 2
          assert_match I18n.t('permission_forge.resource_actions.managed_note.title'), response.body
          assert_match I18n.t('permission_forge.resource_actions.managed_note.unmanaged_allowed'), response.body
          assert_select '.pf-banner--warn', count: 0
        end
      end

      test 'discovered actions can be added per row and in bulk' do
        discovering do
          get pf("#{@base}?tab=actions")

          %w[archive merge].each do |key|
            assert_select "select[form=pf-res-form][name='pf[new_actions][#{@resource.id}][#{key}][is_permitted]'] option", count: 3
            assert_select "a[data-pf-modal=drawer][href='#{pf("#{@base}/actions/new?key=#{key}")}']"
          end
          assert_select "select[name='pf[new_actions][#{@resource.id}][export][is_permitted]']", count: 0
          assert_select "select#pf-bulk-actions[form=pf-res-form][name='pf[bulk_actions][is_permitted]']"
          assert_select "input[type=hidden][name='pf[bulk_actions][resource_id]'][value='#{@resource.id}']"
          assert_select 'label[for=pf-bulk-actions]',
                        text: I18n.t('permission_forge.resources.actions_tab.bulk_label', count: 2)
        end
      end

      test 'an unmanaged action says it is blocked when the strategy blocks' do
        PermissionForge.configuration.unconfigured_action_strategy = :block
        discovering do
          get pf("#{@base}?tab=actions")

          assert_select '.pf-badge--block', text: /⊘ #{I18n.t('permission_forge.resource_actions.effect.unmanaged_blocked')}/, count: 2
          assert_match I18n.t('permission_forge.resource_actions.managed_note.unmanaged_blocked'), response.body
        end
      end

      test 'an action another set manages names the sets that permit it' do
        managers = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: managers, name: 'archive', is_permitted: true)
        discovering do
          get pf("#{@base}?tab=actions")

          assert_match I18n.t('permission_forge.resource_actions.effect.managed_elsewhere'), response.body
          assert_match I18n.t('permission_forge.resource_actions.effect.permitted_by', sets: 'Managers'), response.body
        end
      end

      test 'a configured action with no controller action is marked as not linked' do
        create_resource_action(resource: @resource, name: 'sync', label: 'Sync')
        discovering do
          get pf("#{@base}?tab=actions")

          assert_select '.pf-badge', text: /– #{I18n.t('permission_forge.resources.actions_tab.unlinked')}/, count: 1
          assert_select '.pf-card__row', count: 4
        end
      end

      test 'the tab warns when no controller includes the guard' do
        discovering(guarded: false) do
          get pf("#{@base}?tab=actions")

          assert_select '.pf-banner--warn', count: 1
          assert_match I18n.t('permission_forge.resources.actions_tab.no_guard_title'), response.body
          assert_select '.pf-banner--warn code', text: 'PermissionForge::Concerns::ControllerActionGuard'
        end
      end

      test 'a muting set only offers to add and block' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        resource = create_resource(permission_set: muting)
        discovering do
          get pf("/permission_sets/#{muting.id}/resources/Customer?tab=actions")

          name = "pf[new_actions][#{resource.id}][export][is_permitted]"
          assert_select "select[name='#{name}'] option", count: 2
          assert_select "select[name='#{name}'] option[value='1']", text: I18n.t('permission_forge.resource_actions.add_select.block')
          assert_match I18n.t('permission_forge.resource_actions.effect.managed_elsewhere_muting'), response.body
        end
      end

      test 'a locked set lists discovered actions without any way to add them' do
        @set.update_columns(is_editable: false)
        discovering do
          get pf("#{@base}?tab=actions")

          assert_response :success
          assert_select '.pf-card__row', count: 3
          assert_select 'select', count: 0
          assert_no_match(%r{actions/new}, response.body)
        end
      end

      test 'the tab lists the app\'s own controller actions when no catalog is injected' do
        discovery_on!
        get pf("#{@base}?tab=actions")

        assert_response :success
        assert_match 'customers#export', response.body
        assert_match 'customers#archive', response.body
        assert_select "select[name='pf[new_actions][#{@resource.id}][archive][is_permitted]']"
      end

      # --- discovery on: review → apply -------------------------------------------

      test 'review says the first row makes the action managed, apply adds it' do
        params = new_action_params('archive' => { is_permitted: '1' }, 'merge' => { is_permitted: '' })
        discovering do
          post pf("#{@base}/review"), params: params

          assert_response :success
          assert_match I18n.t('permission_forge.ui.changes.action_new_on', resource: 'Customer', action: 'Archive'), response.body
          assert_match I18n.t('permission_forge.ui.changes.action_managed_first'), response.body
          assert_select '.pf-change-list li', count: 1
          assert_select "input[type=hidden][name='pf[new_actions][#{@resource.id}][archive][is_permitted]'][value='1']"
          assert_not @resource.resource_actions.exists?(name: 'archive')

          patch pf("#{@base}/apply"), params: params
        end

        archive = @resource.resource_actions.find_by(name: 'archive')
        assert archive.is_permitted
        assert_not @resource.resource_actions.exists?(name: 'merge')
        assert PermissionForge::ControllerActions::ManagedIndex.managed_action?('Customer', 'archive')
      end

      test 'review names the sets that already permit a managed action' do
        managers = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: managers, name: 'archive', is_permitted: true)
        create_resource_action(resource: managers, name: 'merge', is_permitted: false)
        discovering do
          post pf("#{@base}/review"), params: new_action_params('archive' => { is_permitted: '0' }, 'merge' => { is_permitted: '1' })

          assert_match I18n.t('permission_forge.ui.changes.action_new_off', resource: 'Customer', action: 'Archive'), response.body
          assert_match I18n.t('permission_forge.ui.changes.action_managed_already', sets: 'Managers'), response.body
          assert_match I18n.t('permission_forge.ui.changes.action_managed_nobody'), response.body
        end
      end

      test 'review of a switched-off set says the row takes effect later' do
        @set.update!(is_active: false)
        discovering do
          post pf("#{@base}/review"), params: new_action_params('archive' => { is_permitted: '1' })

          assert_match I18n.t('permission_forge.ui.changes.action_managed_later'), response.body
          assert_no_match I18n.t('permission_forge.ui.changes.action_managed_first'), response.body
        end
      end

      test 'a muting set reviews and applies a blocking row' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        resource = create_resource(permission_set: muting)
        params = { pf: { new_actions: { resource.id => { 'export' => { is_permitted: '1' } } } } }
        discovering do
          post pf("/permission_sets/#{muting.id}/resources/Customer/review"), params: params
          assert_match I18n.t('permission_forge.ui.changes.action_new_muted', resource: 'Customer', action: 'Export'), response.body
          assert_match I18n.t('permission_forge.ui.changes.action_managed_already', sets: 'Sales rep'), response.body

          patch pf("/permission_sets/#{muting.id}/resources/Customer/apply"), params: params
        end

        assert resource.resource_actions.find_by(name: 'export').is_permitted
      end

      test 'bulk adds every discovered action through review and apply' do
        params = { pf: { bulk_actions: { resource_id: @resource.id, is_permitted: '0' } } }
        discovering do
          post pf("#{@base}/review"), params: params
          assert_select '.pf-change-list li', count: 2

          patch pf("#{@base}/apply"), params: params
        end

        assert_equal %w[archive export merge], @resource.resource_actions.reload.map(&:name).sort
        assert_not @resource.resource_actions.find_by(name: 'merge').is_permitted
      end

      test 'the Permission Set page applies new actions too' do
        params = new_action_params('archive' => { is_permitted: '1' })
        discovering { patch pf("/permission_sets/#{@set.id}/apply"), params: params }

        assert @resource.resource_actions.exists?(name: 'archive')
      end

      test 'keys discovery does not list are never created' do
        discovering do
          post pf("#{@base}/review"), params: new_action_params('drop_table' => { is_permitted: '1' })
          assert_redirected_to pf(@base)

          patch pf("#{@base}/apply"), params: new_action_params('drop_table' => { is_permitted: '1' })
        end

        assert_equal %w[export], @resource.resource_actions.reload.map(&:name)
      end

      test 'locked sets and resources refuse new actions' do
        params = new_action_params('archive' => { is_permitted: '1' })

        @resource.update_columns(is_editable: false)
        discovering { patch pf("#{@base}/apply"), params: params }
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]

        @resource.update_columns(is_editable: true)
        @set.update_columns(is_editable: false)
        discovering { patch pf("#{@base}/apply"), params: params }
        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        discovering { patch pf("/permission_sets/#{@set.id}/apply"), params: params }

        assert_equal %w[export], @resource.resource_actions.reload.map(&:name)
      end

      # --- discovery on: the drawers ----------------------------------------------

      test 'the new drawer suggests discovered keys and explains managed before adding' do
        discovering do
          get pf("#{@base}/actions/new")

          assert_response :success
          assert_select 'input#pf-action-name[list=pf-action-keys]'
          assert_equal(%w[archive merge], css_select('datalist#pf-action-keys option').map { |option| option['value'] })
          assert_match I18n.t('permission_forge.resource_actions.managed_note.title'), response.body
          assert_match I18n.t('permission_forge.resource_actions.managed_note.body'), response.body
          assert_no_match(/pf_stub_guarded/, response.body)
        end
      end

      test 'the new drawer for a discovered action shows where it runs and who permits it' do
        managers = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: managers, name: 'archive', is_permitted: true)
        discovering do
          get pf("#{@base}/actions/new?key=archive")

          assert_select 'input#pf-action-name[value=archive]'
          assert_match 'POST /stub/:id/archive', response.body
          assert_match 'pf_stub_guarded#archive', response.body
          assert_match I18n.t('permission_forge.resource_actions.new.where', action: 'archive'), response.body
          assert_match I18n.t('permission_forge.resource_actions.effect.permitted_by', sets: 'Managers'), response.body
          assert_select '.pf-listbox .pf-option', count: 2
          assert_select '.pf-listbox .pf-option', text: /Managers/
        end
      end

      test 'the new drawer ignores a key outside the key format' do
        discovering do
          get pf("#{@base}/actions/new"), params: { key: '"><b>x' }

          assert_response :success
          assert_select "input#pf-action-name[value='']"
          assert_no_match(/<b>x/, response.body)
        end
      end

      test 'the free-text form still adds an action checked in code' do
        discovering do
          post pf("#{@base}/actions"), params: { resource_action: { name: 'Bad Key!' } }
          assert_response :unprocessable_entity
          assert_select 'datalist#pf-action-keys option', count: 2

          post pf("#{@base}/actions"), params: { resource_action: { name: 'sync', is_permitted: '1', is_active: '1' } }
        end

        assert @resource.resource_actions.find_by(name: 'sync').is_permitted
      end

      test 'the action drawer shows endpoints, or that the action is not linked' do
        sync = create_resource_action(resource: @resource, name: 'sync', label: 'Sync')
        discovering do
          get pf("#{@base}/actions/#{@export.id}")
          assert_match 'GET /stub/export', response.body
          assert_match I18n.t('permission_forge.resource_actions.show.where'), response.body
          assert_select '.pf-badge--grant', text: /✓ #{I18n.t('permission_forge.resource_actions.states.permitted')}/

          get pf("#{@base}/actions/#{sync.id}")
          assert_match I18n.t('permission_forge.resource_actions.show.unlinked'), response.body
          assert_match I18n.t('permission_forge.resource_actions.states.not_permitted'), response.body
        end
      end

      # --- every locale, CSP-safe -------------------------------------------------

      test 'discovery screens render cleanly in every bundled locale' do
        create_resource_action(resource: @resource, name: 'sync', label: 'Sync')
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        create_resource_action(resource: create_resource(permission_set: muting), name: 'archive', is_permitted: true)
        paths = ["#{@base}?tab=actions", "#{@base}/actions/new", "#{@base}/actions/new?key=archive",
                 "#{@base}/actions/#{@export.id}", "/permission_sets/#{muting.id}/resources/Customer?tab=actions"]

        [true, false].each do |guarded|
          discovering(guarded: guarded) do
            PermissionForge::BUNDLED_LOCALES.each do |locale|
              paths.each do |path|
                get pf(path), params: { locale: locale }

                assert_response :success, "#{locale} #{path}"
                assert_no_missing_translations
                assert_clean_markup(path)
              end
              post pf("#{@base}/review"), params: new_action_params('merge' => { is_permitted: '1' }).merge(locale: locale)
              assert_response :success
              assert_no_missing_translations
            end
          end
        end
      end
    end
  end
end
