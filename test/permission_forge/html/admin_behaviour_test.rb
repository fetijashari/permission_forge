require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Behaviour found in the 0.14.1 field test (pf-showcase, b-admin-ui): what a
    # screen shows matches what saving it would do.
    class AdminBehaviourTest < AdminTestCase
      ASSETS = PermissionForge::Engine.root.join('app/frontend/permission_forge')

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      def rules_base
        "/permission_sets/#{@set.id}/resources/Customer/rules"
      end

      def own_supplier_rule(**attrs)
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own', field_accessor_path: 'supplier',
                                   join_type: 'joins', field_name: 'owner_id', operator: 'equal', field_value: 'current_user',
                                   include_nulls: false, **attrs)
      end

      # --- b-admin-ui #20: rule builder preview ---------------------------------------------

      test 'the rule preview names the current user once it is ticked, without a doubled period' do
        post pf("#{rules_base}/refresh"), params: { locale: 'en', rule: { name: 'Own', path: ['supplier'], field_name: 'owner_id',
                                                                          operator: 'equal', current_user: '1' } }

        assert_response :success
        assert_select '[data-pf-rule-preview] .pf-sentence .pf-token--value', text: t('ui.rules.current_user')
        assert_select "[data-pf-rule-preview][data-pf-current-user='#{t('ui.rules.current_user')}'][data-pf-empty='…']"
        assert_not_includes body, '….'
      end

      test 'the rule preview before a value is entered ends in an ellipsis, not "…."' do
        post pf("#{rules_base}/refresh"), params: { rule: { name: 'Own', path: ['supplier'], field_name: 'owner_id',
                                                            operator: 'equal' } }

        assert_select '[data-pf-rule-preview] .pf-token--value', text: '…'
        assert_not_includes body, '….'
      end

      test 'a list operator is previewed on refresh only (no live value token)' do
        post pf("#{rules_base}/refresh"), params: { rule: { name: 'Mine', field_name: 'name', operator: 'in', values_text: 'a,b' } }

        assert_select '[data-pf-rule-preview]', count: 0
        assert_select '.pf-sentence .pf-token--value', text: 'a, b'
      end

      test 'pf_admin.js keeps the preview value in step with the current-user box and the value input' do
        script = ASSETS.join('pf_admin.js').read

        assert_includes script, '[data-pf-rule-preview]'
        assert_includes script, 'input[name="rule[current_user]"], [name="rule[value]"]'
      end

      # --- b-admin-ui #23: toasts and the sticky savebar -----------------------------------

      test 'toasts move to the top of a page that has a savebar' do
        css = ASSETS.join('pf_admin.css').read

        assert_match(/\.pf-root:has\(\.pf-savebar\) \.pf-toasts \{ top: 16px; bottom: auto; \}/, css)
      end

      # --- b-admin-ui #68: Effective access Records cell -----------------------------------

      test 'the Records cell shows the whole rule, wrapped, not cut with an ellipsis' do
        own_supplier_rule
        get pf("/people/#{@ana.id}"), params: { tab: 'effective', locale: 'en' }

        assert_response :success
        assert_select '.pf-state--records .pf-state__summary', text: /owner_id is the current user\z/
        assert_select '.pf-state--records .pf-ellipsis', count: 0
      end

      # --- b-admin-ui #93: Settings health summary and the scoping warning -------------------

      test 'Settings warns about automatic query scoping while Home lists rules it leaves out' do
        own_supplier_rule(join_type: nil, field_accessor_path: nil, field_name: 'name', field_value: 'x')
        PermissionForge.configuration.auto_query_scoping = :off
        get pf('/'), params: { locale: 'en' }
        assert_includes body, t('home.rules_card.scoping_off')

        get pf('/settings'), params: { locale: 'en' }

        assert_select 'section[aria-labelledby=pf-health] .pf-card__row b', text: t('settings.items.auto_query_scoping.name')
        assert_includes body, t('settings.risks.auto_query_scoping')
      end

      test 'Settings does not warn about query scoping when it is on or no rule is in use' do
        get pf('/settings'), params: { locale: 'en' }
        assert_not_includes body, t('settings.risks.auto_query_scoping')

        own_supplier_rule(join_type: nil, field_accessor_path: nil, field_name: 'name', field_value: 'x')
        PermissionForge.configuration.auto_query_scoping = :filter_only
        get pf('/settings'), params: { locale: 'en' }
        assert_not_includes body, t('settings.risks.auto_query_scoping')
      end

      # --- b-admin-ui #104: Edit without Read -------------------------------------------------

      test 'a crafted Edit-without-Read says Edit was not turned on because Read is off' do
        @resource.update!(read_access: false, edit_access: false)
        params = { pf: { resources: { @resource.id => { read_access: '0', edit_access: '1' } } }, locale: 'en' }

        post pf("/permission_sets/#{@set.id}/resources/Customer/review"), params: params

        assert_redirected_to pf("/permission_sets/#{@set.id}/resources/Customer")
        reason = t('ui.changes.not_applied_read', resource: 'Customer', flag: t('ui.flags_short.edit_access'))
        assert_equal t('flash.permission_sets.nothing_applied', reasons: reason), flash[:alert]
        assert_nil flash[:notice]
        assert_not @resource.reload.edit_access
      end

      test 'the review lists a refused flag next to the changes that do apply' do
        @resource.update!(read_access: false, edit_access: false, create_access: false)
        params = { pf: { resources: { @resource.id => { read_access: '0', create_access: '1', edit_access: '1' } } },
                   locale: 'en' }

        post pf("/permission_sets/#{@set.id}/review"), params: params

        assert_response :success
        assert_includes body, t('permission_sets.review.not_applied')
        assert_includes body, t('ui.changes.not_applied_read', resource: 'Customer', flag: t('ui.flags_short.edit_access'))
      end

      test 'nothing refused, nothing to save: the plain notice' do
        params = { pf: { resources: { @resource.id => { read_access: '1', edit_access: '1' } } } }

        post pf("/permission_sets/#{@set.id}/review"), params: params

        assert_equal t('flash.permission_sets.no_changes'), flash[:notice]
      end

      # --- b-admin-ui #118: a locked granting set ----------------------------------------------

      def end_date_options(select_id)
        css_select("select##{select_id} option").map { |option| option['value'] }.compact_blank
      end

      test 'the end-date menu of a locked granting set offers only end dates that narrow' do
        @assignment.update_columns(expires_at: 14.days.from_now.end_of_day)
        @set.update_columns(is_editable: false)

        get pf("/permission_sets/#{@set.id}"), params: { tab: 'assignments' }
        set_menu = end_date_options("pf-sexp-#{@assignment.id}")
        get pf("/people/#{@ana.id}")
        person_menu = end_date_options("pf-exp-#{@assignment.id}")

        [set_menu, person_menu].each do |menu|
          assert_includes menu, '1w'
          assert_not_includes menu, 'never'
          assert_not_includes menu, '30d'
        end
      end

      test 'an unlocked set offers every end date' do
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'assignments' }

        assert_equal PermissionForge::Admin::ExpiryPresets::CHANGE_KEYS, end_date_options("pf-sexp-#{@assignment.id}")
      end

      def extend_form(assignment)
        "form[action='#{pf("/assignments/#{assignment.id}")}'] input[name=expiry][value=extend30]"
      end

      test 'Home offers "Extend 30 days" only where the lock lets it through, and says Locked where not' do
        @assignment.update_columns(expires_at: 3.days.from_now.end_of_day)
        muting_set = create_permission_set(name: 'No exports', is_muting: true)
        muted = create_permission_set_user(user: @bo, permission_set: muting_set, expires_at: 3.days.from_now.end_of_day)
        get pf('/'), params: { locale: 'en' }
        assert_select extend_form(@assignment), count: 1

        @set.update_columns(is_editable: false)
        muting_set.update_columns(is_editable: false)
        get pf('/'), params: { locale: 'en' }

        assert_select extend_form(@assignment), count: 0
        assert_select '.pf-card__row', text: /Ana Krasniqi/ do
          assert_select '.pf-badge', text: /#{t('ui.badges.locked')}/
        end
        assert_select extend_form(muted), count: 1, message: 'extending a Muting Permission Set narrows access'
      end

      test 'a crafted "Extend 30 days" on a locked granting set is still refused' do
        ends = 3.days.from_now.end_of_day.floor(6)
        @assignment.update_columns(expires_at: ends)
        @set.update_columns(is_editable: false)

        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'extend30', return_to: pf('/') }

        assert_equal t('flash.locked_widening'), flash[:alert]
        assert_equal ends, @assignment.reload.expires_at
      end

      test 'the Assign drawer lists a locked granting set as locked, not hidden, and cannot assign it' do
        @set.update_columns(is_editable: false)
        open_set = create_permission_set(name: 'Support')

        get pf('/assignments/new'), params: { user_id: @bo.id, locale: 'en' }

        assert_response :success
        assert_select "input[name='set_ids[]'][value='#{@set.id}'][disabled]"
        assert_select "input[name='set_ids[]'][value='#{open_set.id}']:not([disabled])"
        assert_select '.pf-option', text: /Sales rep/ do
          assert_select '.pf-badge', text: /#{t('ui.badges.locked')}/
        end
        assert_includes body, t('assignments.new.locked_hint')

        assert_no_difference -> { PermissionForge::PermissionSetUser.where(user_id: @bo.id).count } do
          post pf('/assignments'), params: { user_id: @bo.id, set_ids: [@set.id], expiry: 'never' }
        end
        assert_response :unprocessable_entity
      end
    end
  end
end
