require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Wording found in the 0.14.1 field test (pf-showcase, b-admin-ui and
    # a-onboarding): every sentence reads right for the resource, the set and
    # the person it is about, in every locale.
    class AdminCopyTest < AdminTestCase
      LOCALES = %w[en sq mk].freeze

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      def muting_set_with_customer
        set = create_permission_set(name: 'No PII exports', is_muting: true)
        [set, create_resource(permission_set: set, name: 'Customer', read_access: false, create_access: false,
                              edit_access: false, delete_access: false)]
      end

      # b-admin-ui #22: "people with this set see every Customers they can read".
      test 'the empty Rules tab names the resource in the singular, in every locale' do
        LOCALES.each do |locale|
          get pf("/permission_sets/#{@set.id}/resources/Customer"), params: { tab: 'rules', locale: locale }

          assert_response :success
          I18n.with_locale(locale) do
            assert_includes body, t('resources.rules_tab.empty', resource: 'Customer')
          end
          assert_no_missing_translations
        end
        assert_not_includes body, 'every Customers'
      end

      # b-admin-ui #34: "take access away from No PII exports's people".
      test 'the muting banner quotes the set name instead of a possessive' do
        set, = muting_set_with_customer
        get pf("/permission_sets/#{set.id}/resources/Customer"), params: { locale: 'en' }

        assert_includes body, 'Settings here take access away from everyone who has “No PII exports”.'
        assert_not_includes body, "exports's"
      end

      # b-admin-ui #33: in a Muting Permission Set a field without a setting takes nothing away;
      # "Blocked by default" (unconfigured_field_strategy) is what a granting set does.
      # Round 3 (b #38): it is on Unchanged, the one name of "mutes nothing" (no second badge).
      test 'an unconfigured field of a Muting Permission Set says it mutes nothing, not blocked by default' do
        set, resource = muting_set_with_customer
        get pf("/permission_sets/#{set.id}/resources/Customer"), params: { locale: 'en' }

        assert_response :success
        assert_select "input[type=radio][name='pf[new_fields][#{resource.id}][email][level]'][value=leave][checked]", 1
        not_muted = t('resources.fields_tab.not_configured', state: t('ui.states.field_level.none'), behaviour: t('resources.fields_tab.mutes_nothing'))
        assert_select '.pf-badge', text: not_muted, count: 0
        assert_select "a.pf-badge[href*='unconfigured_field_strategy']", count: 0
        assert_not_includes body, t('ui.unconfigured.block')
      end

      test 'the field drawer of a Muting Permission Set explains the unconfigured field the same way' do
        set, = muting_set_with_customer
        get pf("/permission_sets/#{set.id}/resources/Customer/fields/email"), params: { locale: 'en' }

        assert_response :success
        assert_includes body, t('resource_fields.show.not_configured_muting', set: set.name)
        assert_select "a[href*='focus=unconfigured_field_strategy']", count: 0
      end

      test 'a granting set still shows the unconfigured-field strategy' do
        get pf("/permission_sets/#{@set.id}/resources/Customer"), params: { locale: 'en' }

        assert_select "a.pf-badge[href*='unconfigured_field_strategy']", minimum: 1
      end

      # a-onboarding #42: with the "User #2" fallback label the person page read
      # "What User can do right now" (the first word of the label).
      test 'a person labelled by the fallback is named in full on the person page' do
        nameless = create_user(name: nil, email: nil)
        label = t('shared.user_fallback', id: nameless.id)
        get pf("/people/#{nameless.id}"), params: { tab: 'effective', locale: 'en' }

        assert_response :success
        assert_includes body, t('people.access_tab.empty', name: label)
        assert_not_includes body, t('people.access_tab.empty', name: 'User')
      end

      test 'a person with a name is still called by the first name' do
        get pf("/people/#{@bo.id}"), params: { tab: 'effective', locale: 'en' }

        assert_includes body, t('people.access_tab.empty', name: 'Bo')
      end
    end
  end
end
