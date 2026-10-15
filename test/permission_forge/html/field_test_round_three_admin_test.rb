require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Admin findings of the third recorded field test (pf-showcase-3,
    # b-admin-ui and e-operations): the Assignments grid's columns, Home's
    # privacy audit on a locked set, one name for "mutes nothing", the Fields
    # grid's level controls, the cache refresh wording and the event page of
    # a change with no actor.
    class FieldTestRoundThreeAdminTest < AdminTestCase
      LOCALES = %w[en sq mk].freeze
      CSS = File.read(File.expand_path('../../../app/frontend/permission_forge/pf_admin.css', __dir__))

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      # The `grid-template-columns` of the CSS rule whose selector list is exactly `selector`.
      def grid_template(selector)
        rules = CSS.scan(/^\s*([^{}@]+?)\s*\{([^}]*)\}/).select { |sel, _| sel.split(',').map(&:strip) == [selector] }
        rules.filter_map { |_, body| body[/grid-template-columns:\s*([^;]+);/, 1] }.last
      end

      # --- 1. Assignments grid (b #23) ----------------------------------------------

      # Each row was its own grid: the `auto` actions column took its width from that row's
      # content and the header's (empty) one, so "Until 14 Nov" sat under "Assigned".
      test 'every row of the Assignments grid has as many cells as the header has columns' do
        create_permission_set_user(user: @bo, permission_set: @set, expires_at: 30.days.from_now)
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'assignments' }

        assert_response :success
        headers = css_select('.pf-table--assignments > .pf-table__head > [role=columnheader]').size
        rows = css_select('.pf-table--assignments > .pf-table__row')
        assert_equal 5, headers
        assert_equal 2, rows.size
        rows.each { |row| assert_equal headers, row.css('> [role=cell]').size }
      end

      test 'a table with a content-sized column shares one grid between its head and rows (subgrid)' do
        subgrid = CSS[/@supports \(grid-template-columns: subgrid\) \{(.*?)\n\}/m, 1]
        assert subgrid, 'pf_admin.css has a subgrid block'

        %w[sets assignments].each do |table|
          template = grid_template(".pf-table--#{table}")
          assert template, ".pf-table--#{table} declares its columns on the table"
          assert_equal 5, template.scan(/minmax\([^)]*\)|fit-content\([^)]*\)|\S+/).size
          # A subgrid adds its padding to the edge tracks: a fixed width there would squeeze them.
          edges = template.scan(/minmax\([^)]*\)|fit-content\([^)]*\)|\S+/).values_at(0, -1)
          edges.each { |track| assert_no_match(/\A\d+px\z/, track, "#{table}: edge track #{track} is fixed") }
          assert_includes subgrid, ".pf-table--#{table} > .pf-table__row"
          assert_includes subgrid, ".pf-table--#{table} > .pf-table__head"
        end
        assert_match(/grid-template-columns: subgrid/, subgrid)
      end

      test 'every table whose rows have a content-sized column is on the shared grid' do
        CSS.scan(/^\.pf-table--([a-z]+) \.pf-table__head, \.pf-table--\1 \.pf-table__row \{ grid-template-columns: ([^;]+);/)
           .each do |table, template|
          next unless template.split.include?('auto')

          assert grid_template(".pf-table--#{table}"), "#{table} has an auto column and no shared grid"
        end
      end

      # --- 2. Privacy audit on a locked set (b #85) ---------------------------------

      def unmasked_name
        create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: false)
      end

      def assert_privacy_row(name, &)
        assert_select('#pf-card-privacy ~ * .pf-card__row, section[aria-labelledby=pf-card-privacy] .pf-card__row',
                      text: /#{name}/, minimum: 1, &)
      end

      test 'the privacy audit offers Fix and This is intended for a field of an editable set' do
        unmasked_name
        get pf('/'), params: { privacy: 'all' }

        assert_privacy_row('name') do
          assert_select 'a', text: t('home.privacy_card.fix')
          assert_select 'button', text: t('home.privacy_card.intended')
          assert_select '.pf-badge', text: /#{t('ui.badges.locked')}/, count: 0
        end
      end

      # The field drawer refuses every change to a locked set's field (EditableLock): Home said
      # "Fix" and "This is intended" anyway, and the drawer then offered nothing.
      test 'the privacy audit shows a field of a locked set as Locked, with no Fix and no This is intended' do
        unmasked_name
        @set.update_columns(is_editable: false)
        get pf('/'), params: { privacy: 'all' }

        assert_privacy_row('name') do
          assert_select '.pf-badge', text: /#{t('ui.badges.locked')}/, count: 1
          assert_select 'a', text: t('home.privacy_card.fix'), count: 0
          assert_select 'button', text: t('home.privacy_card.intended'), count: 0
          assert_select "a[href$='/fields/name']", text: t('home.privacy_card.view')
        end
        # A field with no row in the locked set: adding one is a change too.
        assert_privacy_row('full_address') do
          assert_select 'a', text: t('home.privacy_card.fix'), count: 0
        end
      end

      test 'a privacy finding is locked by its field, its Resource or its Permission Set' do
        name = unmasked_name
        finding = -> { Admin::AttentionItems.new.privacy_findings.find { |f| f.name == 'name' } }
        assert_not finding.call.locked?

        name.update_columns(is_editable: false)
        assert_predicate finding.call, :locked?
        name.update_columns(is_editable: true)
        @resource.update_columns(is_editable: false)
        assert_predicate finding.call, :locked?
      end

      test 'the drawer of a locked field does not say what saving would do' do
        unmasked_name
        @set.update_columns(is_editable: false)
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/name")

        assert_select '.pf-sheet__footer-note', text: t('resource_fields.show.locked_impact')
        assert_not_includes body, t('resource_fields.show.impact', people: '1 person')
        assert_select 'button[type=submit]', text: t('resource_fields.show.save'), count: 0
      end

      test 'the drawer of an editable field still says what saving does' do
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")

        assert_select '.pf-sheet__footer-note', text: t('resource_fields.show.impact', people: '1 person')
      end

      # --- 3. A Muting Permission Set's field with no setting (b #38) --------------

      def muting_customer
        set = create_permission_set(name: 'No PII exports', is_muting: true)
        [set, create_resource(permission_set: set, name: 'Customer', read_access: false, create_access: false,
                              edit_access: false, delete_access: false)]
      end

      test 'in a Muting Permission Set a column with no setting is on Unchanged, counted under Unchanged' do
        set, resource = muting_customer
        get pf("/permission_sets/#{set.id}/resources/Customer"), params: { locale: 'en' }

        assert_response :success
        rows = Admin::FieldRows.new(resource).rows
        assert_predicate rows.size, :positive?
        assert_select "a.pf-filter[href*='filter=leave']", text: /#{t('resources.fields_tab.filters.leave')}\s*#{rows.size}/
        assert_select "a.pf-filter[href*='filter=unconfigured']", count: 0
        assert_select "input[type=radio][value=leave][checked][name^='pf[new_fields]']", rows.size
        assert_not_includes body, t('resources.fields_tab.not_configured', behaviour: t('resources.fields_tab.mutes_nothing'))
      end

      test 'saving a muting column left on Unchanged creates no field row' do
        set, resource = muting_customer
        changes = Admin::ChangeSet.new(permission_set: set,
                                       params: { new_fields: { resource.id.to_s => { 'email' => { 'level' => 'leave' } } } })
                                  .apply!

        assert_empty changes
        assert_empty resource.resource_fields.reload
      end

      test 'a turned-off muting row keeps its saved choice and says it mutes nothing' do
        set, resource = muting_customer
        create_resource_field(resource: resource, name: 'email', read_access: false, mask_access: true, is_active: false)
        get pf("/permission_sets/#{set.id}/resources/Customer"), params: { locale: 'en' }

        assert_select '.pf-badge', text: t('resources.fields_tab.turned_off', behaviour: t('resources.fields_tab.mutes_nothing'))
      end

      test 'the field drawer and Across all Permission Sets call a muting column with no setting Unchanged' do
        set, = muting_customer
        get pf("/permission_sets/#{set.id}/resources/Customer/fields/email"), params: { locale: 'en' }

        assert_select 'input[type=radio][name="field[level]"][value=leave][checked]', 1
        assert_select '.pf-option[aria-current=true] .pf-level-badge--leave', 1
      end

      test 'a granting set keeps Not configured for a column with no setting' do
        rows = Admin::FieldRows.new(@resource)

        assert_includes rows.filters, 'unconfigured'
        assert_nil rows.row('domain').level
      end

      # --- 4. Fields grid: the level controls line up (b #67) -----------------------

      test 'the mask preview sits under the level control, inside its column' do
        get pf("/permission_sets/#{@set.id}/resources/Customer")

        row = css_select('.pf-fields__row').find { |node| node.at_css('code.pf-mono-key')&.text == 'email' }
        assert row
        assert_empty row.css('> .pf-mask-preview'), 'the preview is not a cell of its own'
        level = row.at_css('> .pf-fields__level')
        assert level
        assert level.at_css('> [role=radiogroup]')
        assert_match(/\A#{t('ui.mask_strategies.email')} · \S+@\S+\z/, level.at_css('> .pf-mask-preview').text.squish)
        # A row that is not masked has the same column, with no preview.
        plain = css_select('.pf-fields__row').find { |node| node.at_css('code.pf-mono-key')&.text == 'domain' }
        assert_empty plain.css('.pf-mask-preview')
        assert plain.at_css('> .pf-fields__level > [role=radiogroup]')
      end

      test 'the preview does not widen the level column' do
        assert_match(/\.pf-fields__level > \.pf-mask-preview \{[^}]*contain: inline-size/, CSS)
      end

      # --- 5. Refresh cached permissions (e #20) -------------------------------------

      test 'Refresh cached permissions says when it is needed, in every locale' do
        LOCALES.each do |locale|
          get pf("/people/#{@ana.id}"), params: { locale: locale }

          assert_response :success
          assert_no_missing_translations
          I18n.with_locale(locale) do
            assert_includes body, t('people.show.menu.refresh.desc')
            assert_match(/memory store/, t('people.show.menu.refresh.desc'))
          end
        end
        assert_not_includes body, 'changes already apply immediately'
      end

      # --- 6. The event page of a change with no actor (e #73) -----------------------

      def enable_audit_trail_without_resolver
        config = PermissionForge.configuration
        old_resolver = config.current_user_resolver
        config.audit_trail_enabled = true
        config.current_user_resolver = -> {}
        yield
      ensure
        config.current_user_resolver = old_resolver
      end

      def who_card
        css_select('section[aria-labelledby=pf-event-who]').first
      end

      test 'the event page of a change with no actor explains Unknown and links to every such event' do
        enable_audit_trail_without_resolver do
          @set.update!(description: 'Changed from a runner')
          event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_type: 'unknown')

          get pf("/audit/#{event.uuid}"), params: { locale: 'en' }

          assert_response :success
          unknown = t('audit_log.actor_types.unknown')
          assert_not_includes who_card.text.squish, "#{unknown} · #{unknown}"
          assert_equal 'PermissionForge.with_audit_actor', who_card.at_css('code').text
          assert_match(/no actor was named for this change/, who_card.text)
          link = who_card.css('a').find { |a| a.text == t('audit_events.show.all_unknown_actor') }
          assert link
          assert_includes link['href'], 'actor_type=unknown'
          assert_empty(who_card.css('a').select { |a| a.text == t('audit_events.show.all_by_actor') })
        end
      end

      test 'the event page of a named actor keeps its type and the link to its events, with no hint' do
        enable_audit_trail_without_resolver do
          PermissionForge.with_audit_actor(user: @bo) { @set.update!(description: 'Changed by Bo') }
          event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_id: @bo.id.to_s)

          get pf("/audit/#{event.uuid}"), params: { locale: 'en' }

          assert_select 'section[aria-labelledby=pf-event-who] a', text: t('audit_events.show.all_by_actor')
          assert_nil who_card.at_css('code')
        end
      end

      test 'the unknown-actor explanation on the event page reads in every locale' do
        enable_audit_trail_without_resolver do
          @set.update!(description: 'Changed from a runner')
          event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_type: 'unknown')
          LOCALES.each do |locale|
            get pf("/audit/#{event.uuid}"), params: { locale: locale }

            assert_no_missing_translations
            I18n.with_locale(locale) { assert_includes body, t('audit_events.show.all_unknown_actor') }
          end
        end
      end
    end
  end
end
