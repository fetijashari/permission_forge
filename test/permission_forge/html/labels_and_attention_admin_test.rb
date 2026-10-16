require_relative 'admin_test_case'
require 'permission_forge/sti_models'

module PermissionForge
  module Html
    # WP-10's admin pages: the hours error of the Conditions tab, the field
    # drawer's "Explain for" naming the entry that decides an inherited
    # field, the record footer naming an unknown actor once, Settings' health
    # summary reading Home's attention items, and Home's new cards.
    class LabelsAndAttentionAdminTest < AdminTestCase
      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      # --- Conditions: the hours error has its slot ----------------------------------

      test 'the same start and end hour is said next to the hour selects, which are marked invalid' do
        patch pf("/permission_sets/#{@set.id}/conditions"),
              params: { hours_enabled: '1', allowed_hours_start: '9', allowed_hours_end: '9', allowed_ips: '' }

        assert_response :unprocessable_entity
        error = css_select('#pf-hours-error').first
        assert error, 'the hours error has a slot'
        assert_equal t('errors.admin.hours_equal'), error.text.strip
        %w[pf-hours-from pf-hours-to].each do |id|
          select = css_select("##{id}").first
          assert_equal 'true', select['aria-invalid'], "#{id} is marked invalid"
          assert_includes select['aria-describedby'].to_s, 'pf-hours-error'
        end
      end

      test 'valid hours draw no hours error' do
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'conditions' }

        assert_response :success
        assert_empty css_select('#pf-hours-error')
        assert_nil css_select('#pf-hours-from').first['aria-invalid']
      end

      # --- Explain for: the entry that decides an inherited field -----------------------

      test 'Explain for names the base Resource that decides an inherited field, as the Why panel does' do
        base = create_resource(permission_set: @set, name: 'PfStiTicket', read_access: true, edit_access: true)
        create_resource_field(resource: base, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        sub = create_resource(permission_set: @set, name: 'PfStiBugTicket', read_access: true, edit_access: true)
        create_resource_field(resource: sub, name: 'email', read_access: true, edit_access: true)

        get pf("/people/#{@ana.id}"), params: { tab: 'effective', open: ['PfStiBugTicket'], why: 'PfStiBugTicket.field.email' }
        reasons = css_select("[id='pf-why-PfStiBugTicket.field.email'] .pf-why__reason")
        decided = reasons.find { |reason| reason.at_css('span[aria-hidden]').text == '↑' }
        assert decided, 'the Why panel names the deciding entry'
        sentence = decided.css('span span').first.text.squish

        get pf("/permission_sets/#{@set.id}/resources/PfStiBugTicket/fields/email"), params: { explain_user_id: @ana.id }

        assert_response :success
        assert_includes css_select('.pf-panel').map { |node| node.text.squish }.join(' '), sentence,
                        'Explain for words it as the Why panel does'
      end

      # --- the footer names an unknown actor once ----------------------------------------

      test 'a record created and edited with no known actor reads Unknown once in its footer' do
        config = PermissionForge.configuration
        old_trail = config.audit_trail_enabled
        old_resolver = config.current_user_resolver
        config.audit_trail_enabled = true
        config.current_user_resolver = -> {}
        set = create_permission_set(name: 'Runner set')
        set.update!(description: 'Changed from a runner')

        get pf("/permission_sets/#{set.id}")

        assert_response :success
        footer = css_select('footer.pf-audit-footer').first.text.squish
        unknown = PermissionForge::Admin::StateLabel.word(:actor, :unknown)
        assert_equal 1, footer.scan(unknown).size, footer
        assert_match(/no actor was named/i, footer)
      ensure
        config.audit_trail_enabled = old_trail
        config.current_user_resolver = old_resolver
      end

      # --- Settings reads Home --------------------------------------------------------

      test 'Settings never says the settings look good while Home lists items that need attention' do
        create_resource_field(resource: @resource, name: 'name', read_access: true, mask_access: false)
        count = PermissionForge::Admin::AttentionItems.new.total
        assert_operator count, :>, 0

        get pf('/settings')

        assert_response :success
        health = css_select('section[aria-labelledby=pf-health]').first
        assert_no_match(/look(s)? good/i, health.text)
        link = health.css('a').find { |a| a['href'] == pf('/') }
        assert link, 'the health summary links to Home'
        assert_includes health.text.squish, t('settings.show.attention', count: count)
      end

      test 'Settings says the settings look good when Home has nothing either' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        skip 'Home still lists something in the suite configuration' unless PermissionForge::Admin::AttentionItems.new.all_good?

        get pf('/settings')

        assert_match(/look(s)? good/i, css_select('section[aria-labelledby=pf-health]').first.text)
      end

      # --- Home's cards -------------------------------------------------------------------

      test 'Home lists a field masked with a strategy this app does not know, with a link to the field' do
        @email.update_columns(mask_strategy: 'rot13')

        get pf('/')

        card = css_select('section[aria-labelledby=pf-card-mask-strategies]').first
        assert card, 'the unknown mask strategies card'
        assert_includes card.text, 'rot13'
        assert(card.css('a').any? { |a| a['href'].include?("/permission_sets/#{@set.id}/resources/Customer/fields/email") })
      end

      test 'Home lists a set whose activation conditions nobody can judge, with a link to its Conditions tab' do
        @set.update!(allowed_hours_start: 9, allowed_hours_end: 17)
        @set.update_columns(allowed_hours_end: 9)

        get pf('/')

        card = css_select('section[aria-labelledby=pf-card-conditions]').first
        assert card, 'the conditions card'
        assert_includes card.text, @set.name
        assert(card.css('a').any? { |a| a['href'].include?("/permission_sets/#{@set.id}") && a['href'].include?('conditions') })
      end
    end
  end
end
