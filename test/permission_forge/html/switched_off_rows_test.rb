require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The engine skips a field row that is switched off. The home privacy card
    # and the "Across all Permission Sets" list say so: the card does not call
    # the field "not configured", and the list does not show the row's level as
    # if it were in force.
    class SwitchedOffRowsTest < AdminTestCase
      setup do
        @config = PermissionForge.configuration
        @drawer = "/permission_sets/#{@set.id}/resources/Customer/fields"
      end

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def setting_href(key)
        "#{ROOT}/settings?focus=#{key}#set-#{key}"
      end

      def where(key, set: @set)
        t("home.privacy_card.#{key}", resource: 'Customer', set: set.name, people: '1 person')
      end

      def switch_off_full_address
        create_resource_field(resource: @resource, name: 'full_address', label: 'Full address', read_access: false,
                              is_active: false)
      end

      # The card row of one field: yields inside its element.
      def assert_privacy_row(name, &)
        assert_select('.pf-card__row', text: /#{name}/, count: 1, &)
      end

      # --- Home: privacy card ---------------------------------------------------

      test 'the privacy card says a switched-off row of a virtual field is turned off' do
        switch_off_full_address
        get pf('/'), params: { privacy: 'all' }

        assert_response :success
        assert_privacy_row('full_address') do
          assert_select '.pf-badge--off', text: /#{t('ui.badges.off')}/, count: 1
          assert_select '.pf-badge', text: t('ui.states.field_level.none'), count: 0
          assert_select 'strong', text: 'Full address'
        end
        body = CGI.unescapeHTML(response.body)
        assert_includes body, where('where_turned_off_virtual')
        assert_not_includes body, where('where_virtual')
      end

      test 'the privacy card says a switched-off row of a column is turned off' do
        @email.update!(is_active: false)
        get pf('/'), params: { privacy: 'all' }

        assert_privacy_row('email') do
          assert_select '.pf-badge--off', count: 1
          assert_select '.pf-badge', text: t('ui.states.field_level.none'), count: 0
        end
        assert_includes CGI.unescapeHTML(response.body), where('where_turned_off')
      end

      test 'a field with no row is still not configured, with the link to the setting that decides' do
        switch_off_full_address
        get pf('/'), params: { privacy: 'all' }

        assert_privacy_row('name') do
          assert_select '.pf-badge--off', count: 0
          assert_select "a.pf-badge--unconfigured[href='#{setting_href('unconfigured_field_strategy')}']",
                        text: t('ui.states.field_level.none')
        end
        assert_includes CGI.unescapeHTML(response.body), where('where_unconfigured')
      end

      test 'the card summary counts switched-off rows apart from fields that are not configured' do
        get pf('/')
        summary = t('home.privacy_card.turned_off', count: 1)
        assert_not_includes response.body, summary
        assert_includes response.body, t('home.privacy_card.unconfigured', count: 2)

        switch_off_full_address
        get pf('/')

        assert_select '.pf-card__desc', text: /#{Regexp.escape(summary)}/
        assert_includes response.body, t('home.privacy_card.unconfigured', count: 1)
        assert_not_includes response.body, t('home.privacy_card.unconfigured', count: 2)
      end

      # A line describes one set on its own; someone who also holds a set that
      # configures the field follows that set, and the card says so.
      test 'the card notes that its not-configured and turned-off lines look at one set on its own' do
        switch_off_full_address
        get pf('/'), params: { privacy: 'all' }

        assert_includes CGI.unescapeHTML(response.body), t('home.privacy_card.per_set_note')
      end

      test 'the note is left out when every finding is a configured, unmasked field' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        PermissionForge.configuration.unconfigured_field_strategy = :block
        get pf('/'), params: { privacy: 'all' }

        assert_response :success
        assert_not_includes CGI.unescapeHTML(response.body), t('home.privacy_card.per_set_note')
      end

      test 'Fix on a switched-off row opens the drawer, which says what applies and has the switch' do
        switch_off_full_address
        get pf('/'), params: { privacy: 'all' }

        assert_privacy_row('full_address') do
          assert_select "a[href='#{pf("#{@drawer}/full_address")}']", text: t('home.privacy_card.fix')
          assert_select 'form', count: 0
        end

        get pf("#{@drawer}/full_address")
        assert_response :success
        assert_includes CGI.unescapeHTML(response.body), t('resource_fields.show.turned_off_implicit', set: @set.name)
        assert_select "input[type='checkbox'][name='field[is_active]']:not([checked])"
      end

      test 'a switched-off row in a muting Permission Set is no privacy finding' do
        muting = create_permission_set(name: 'Contractors', is_muting: true)
        resource = create_resource(permission_set: muting)
        create_resource_field(resource: resource, name: 'full_address', read_access: true, is_active: false)
        create_resource_field(resource: @resource, name: 'full_address', read_access: true, mask_access: true)
        get pf('/'), params: { privacy: 'all' }

        assert_select '.pf-card__row code', text: 'full_address', count: 0
      end

      # --- Field drawer and field lookup: the field in every Permission Set ----------

      # Sales rep (the set the drawer is opened from) keeps an active row.
      # Returns the names of the sets whose email row does not count.
      def other_sets_with_rows_not_in_effect
        managers = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_field(resource: managers, name: 'email', read_access: true, edit_access: true, is_active: false)
        support = create_resource(permission_set: create_permission_set(name: 'Support'), is_active: false)
        create_resource_field(resource: support, name: 'email', read_access: true)
        interns = create_resource(permission_set: create_permission_set(name: 'Interns', is_active: false))
        create_resource_field(resource: interns, name: 'email', read_access: true)
        contractors = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_field(resource: contractors, name: 'email', read_access: true, is_active: false)
        %w[Managers Support Interns Contractors]
      end

      # expected: { set name => whether its row in the list carries the Off badge }
      def assert_off_badges(expected)
        expected.each do |name, off|
          assert_select '.pf-listbox .pf-option', text: /#{name}/, count: 1 do
            assert_select '.pf-badge--off', { count: off ? 1 : 0 }, "#{name}: Off badge expected #{off}"
          end
        end
      end

      test 'the drawer marks a row that is not in effect in another Permission Set as Off' do
        expected = other_sets_with_rows_not_in_effect.index_with { true }
        get pf("#{@drawer}/email")

        assert_response :success
        assert_off_badges(expected.merge('Sales rep' => false))
        assert_select '.pf-listbox .pf-option', text: /Managers/ do
          assert_select '.pf-level-badge--edit', count: 1
        end
        assert_select '.pf-listbox .pf-option', text: /Contractors/ do
          assert_select '.pf-level-badge--hide', text: /#{t('ui.states.field_level.hide')}/
        end
      end

      test 'the drawer marks its own switched-off row as Off in the list' do
        @email.update!(is_active: false)
        get pf("#{@drawer}/email")

        assert_off_badges('Sales rep' => true)
        assert_select ".pf-listbox .pf-option[aria-current='true'] .pf-badge--off", count: 1
      end

      test 'a switched-off row of a virtual field is marked Off as well' do
        switch_off_full_address
        get pf("#{@drawer}/full_address")

        assert_off_badges('Sales rep' => true)
      end

      test 'a set without a row is Off only when its resource or the set is off' do
        create_resource(permission_set: create_permission_set(name: 'Finance'))
        create_resource(permission_set: create_permission_set(name: 'Legal'), is_active: false)
        get pf("#{@drawer}/email")

        assert_off_badges('Finance' => false, 'Legal' => true)
        assert_select '.pf-listbox .pf-option', text: /Legal/ do
          assert_select '.pf-level-badge', text: /#{t('ui.states.field_level.none')}/
        end
      end

      test 'field lookup marks rows that are not in effect the same way' do
        expected = other_sets_with_rows_not_in_effect.index_with { true }
        get pf('/field_lookup'), params: { resource: 'Customer', field: 'email' }

        assert_response :success
        assert_off_badges(expected.merge('Sales rep' => false))
      end

      # --- Every locale, strict CSP ---------------------------------------------------

      test 'the card and the lists render cleanly in every locale and mode' do
        switch_off_full_address
        @email.update!(is_active: false)
        other_sets_with_rows_not_in_effect
        paths = ['/', '/?privacy=all', "#{@drawer}/email", "#{@drawer}/full_address",
                 '/field_lookup?resource=Customer&field=email', '/field_lookup?resource=Customer&field=full_address']

        %i[grant unconfigured].each do |mode|
          @config.extra_fields_default_access = mode
          PermissionForge::BUNDLED_LOCALES.each do |locale|
            paths.each do |path|
              get pf(path), params: { locale: locale }
              assert_response :success, "#{mode} #{locale} #{path}"
              assert_no_missing_translations
              assert_csp_safe(path)
            end
          end
        end
      end

      private

      def assert_csp_safe(path)
        body = response.body
        assert_no_match(/\sstyle="/, body, "inline style on #{path}")
        assert_no_match(/<script(?![^>]*\ssrc=)/, body, "inline script on #{path}")
        assert_no_match(/\son[a-z]+="/, body, "inline handler on #{path}")
        classes = body.scan(/class="([^"]*)"/).flatten.flat_map(&:split).uniq
        assert_empty classes.reject { |c| c.start_with?('pf-') }, "unprefixed classes on #{path}"
      end
    end
  end
end
