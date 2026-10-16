require_relative 'admin_test_case'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 7 (E#32, B#48a): what the Conditions tab says about a
    # set's activation conditions comes from the definition that judges them
    # (ActivationConditions: HoursWindow, condition_problems, ip_range) —
    # never a re-derivation. A window from 9 to 9 is not "overnight"; the
    # tab does not send the reader to the tab they are on; a list with an
    # entry that is no address says so, in one banner with the effect Home
    # names (a granting set grants nothing, a muting set applies to every
    # request); the form refuses what the model refuses, for the same reason.
    class ConditionsExplanationsTest < AdminTestCase
      def conditions_tab(set, locale: 'en')
        get pf("/permission_sets/#{set.id}"), params: { tab: 'conditions', locale: locale }
        assert_response :success
        Nokogiri::HTML(response.body)
      end

      def overnight_line(doc)
        doc.css('fieldset span').find { |node| node.text.include?('☾') }
      end

      def broken_set(muting: false, **columns)
        create_permission_set(name: "Broken #{SecureRandom.hex(3)}", is_muting: muting).tap { |set| set.update_columns(columns) }
      end

      # --- E#32 ------------------------------------------------------------------------

      test 'a window from an hour to the same hour is never shown as overnight, nor sent to the tab it is on' do
        set = broken_set(allowed_hours_start: 9, allowed_hours_end: 9)

        doc = conditions_tab(set)
        assert_nil overnight_line(doc), '9 to 9 is no overnight window'
        assert_not_includes doc.text, 'on the Conditions tab', 'the tab does not send the reader to itself'
        assert_includes doc.text, I18n.t('permission_forge.ui.conditions.hours_broken_here', from: '09:00', to: '09:00')
      end

      test 'an overnight window says so; a daytime one does not' do
        assert overnight_line(conditions_tab(create_permission_set(name: 'Night', allowed_hours_start: 22, allowed_hours_end: 6)))
        assert_nil overnight_line(conditions_tab(create_permission_set(name: 'Day', allowed_hours_start: 8, allowed_hours_end: 18)))
        assert_nil overnight_line(conditions_tab(create_permission_set(name: 'None'))), 'no window: no hint'
      end

      test 'a refused form with the same hour twice shows the error, not an overnight hint' do
        set = create_permission_set(name: 'Refused hours')
        patch pf("/permission_sets/#{set.id}/conditions"),
              params: { hours_enabled: '1', allowed_hours_start: '9', allowed_hours_end: '9', allowed_ips: '' }
        assert_response :unprocessable_entity
        doc = Nokogiri::HTML(response.body)

        assert_equal I18n.t('permission_forge.errors.admin.hours_equal'), doc.at_css('#pf-hours-error').text.strip
        assert_nil overnight_line(doc)
      end

      test 'the form refuses an hour outside the day for the reason the model has' do
        set = create_permission_set(name: 'Out of range')
        patch pf("/permission_sets/#{set.id}/conditions"),
              params: { hours_enabled: '1', allowed_hours_start: '9', allowed_hours_end: '30', allowed_ips: '' }
        assert_response :unprocessable_entity

        assert_equal I18n.t('permission_forge.errors.admin.hours_range'), Nokogiri::HTML(response.body).at_css('#pf-hours-error').text.strip
        assert_nil set.reload.allowed_hours_end
      end

      test 'the form takes an IP entry exactly when ActivationConditions reads it as an address' do
        set = create_permission_set(name: 'IP parity')
        ['10.0.0.0/8', '192.168.1.7', '::1', '2001:db8::/32', 'office-network', '10.0.0.300', '1.2.3', ' '].each do |entry|
          form = PermissionForge::Admin::ConditionsForm.new(ActionController::Parameters.new(allowed_ips: entry))
          form.attributes
          expected = PermissionForge::ActivationConditions.entries(entry).all? { |e| PermissionForge::ActivationConditions.ip_range(e) }
          assert_equal expected, form.errors[:ips].nil?, "#{entry.inspect} (set #{set.id})"
        end
      end

      # --- B#48a -----------------------------------------------------------------------

      { false => 'granting', true => 'muting' }.each do |muting, kind|
        test "a #{kind} set's list with an entry that is no address shows one banner with Home's effect" do
          set = broken_set(muting: muting, allowed_ips: '10.0.0.0/8,office-network')

          doc = conditions_tab(set)
          banner = doc.at_css('[data-pf-condition-problems]')
          assert banner, 'the problem banner'
          assert_includes banner.text, 'office-network'
          effect = I18n.t("permission_forge.ui.conditions.effect.#{kind}")
          assert_includes banner.text, effect
          summary = I18n.t('permission_forge.ui.conditions.ips_broken_here', ips: '10.0.0.0/8 or office-network')
          assert_includes doc.css('strong').map(&:text).join(' '), summary, 'the summary says the list cannot be judged'

          get pf('/')
          assert_includes Nokogiri::HTML(response.body).at_css('#pf-card-conditions').ancestors('section').first.text, effect,
                          'Home words the effect the same way'
        end
      end

      test 'every kind of problem has its sentence in the banner, in every language' do
        sets = {
          ip_entry: broken_set(allowed_ips: 'office-network'),
          ip_empty: broken_set(allowed_ips: ', ,'),
          flag_unusable: broken_set(requires_session_flag: "mfa\nverified"),
          hours_incomplete: broken_set(allowed_hours_start: 9),
          hours_range: broken_set(allowed_hours_start: 9, allowed_hours_end: 30),
          hours_equal: broken_set(allowed_hours_start: 9, allowed_hours_end: 9)
        }
        sets.each do |kind, set|
          assert_equal [kind], set.condition_problems.map(&:first), kind
          %w[en sq mk].each do |locale|
            banner = conditions_tab(set, locale: locale).at_css('[data-pf-condition-problems]')
            assert banner, "#{kind} #{locale}"
            assert_no_match(/translation missing/i, banner.to_html, "#{kind} #{locale}")
            assert_includes banner.text, I18n.t('permission_forge.ui.conditions.effect.granting', locale: locale), "#{kind} #{locale}"
          end
        end
      end

      test 'a set whose conditions can be judged shows no banner' do
        assert_nil conditions_tab(create_permission_set(name: 'Fine', allowed_ips: '10.0.0.0/8')).at_css('[data-pf-condition-problems]')
      end

      test 'the access tab of a person names the broken list and where to fix it' do
        set = broken_set(allowed_ips: 'office-network')
        create_permission_set_user(user: @bo, permission_set: set)

        get pf("/people/#{@bo.id}"), params: { tab: 'access' }
        page = Nokogiri::HTML(response.body)
        assert_includes page.text.squish, I18n.t('permission_forge.ui.conditions.ips_broken', ips: 'office-network')
        assert(page.css('code.pf-mono-key').any? { |code| code.text == 'office-network' }, 'the stored entry is marked as host data')
      end
    end
  end
end
