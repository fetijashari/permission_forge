require_relative 'admin_test_case'

module PermissionForge
  module Html
    # What the admin says about reviews, editors and reasons now that the
    # audit log knows: "Reviewed by … on …" / "Never reviewed", the real last
    # editor in the footer, and an optional reason on every change form.
    class AuditUiLabelsTest < AdminTestCase
      setup do
        PermissionForge.configuration.audit_trail_enabled = true
        @old_resolver = PermissionForge.configuration.current_user_resolver
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      def sign_in(user)
        PermissionForge.configuration.current_user_resolver = -> { user }
      end

      def ui(key, **)
        I18n.t("permission_forge.ui.#{key}", **)
      end

      def date(time)
        ApplicationController.helpers.extend(PermissionForge::ApplicationHelper).pf_date(time)
      end

      # ---- reviews ---------------------------------------------------------------

      test 'Home: a stale assignment says Never reviewed and when and by whom it was granted' do
        @assignment.update_columns(created_at: 200.days.ago, updated_at: 1.day.ago)

        PermissionForge.with_audit_actor(user: @bo) { @bo_grant = create_permission_set_user(user: @bo, permission_set: @set) }
        @bo_grant.update_columns(created_at: 300.days.ago)

        get pf('/')

        card = css_select('section[aria-labelledby=pf-card-stale]').first.text.squish
        assert_match "⚠ #{ui('assignment.never_reviewed')}", card
        assert_match I18n.t('permission_forge.home.stale_card.assigned', date: date(300.days.ago), by: 'Bo Berisha'), card
        assert_match I18n.t('permission_forge.home.stale_card.assigned', date: date(200.days.ago),
                                                                         by: I18n.t('permission_forge.ui.states.actor.unknown')), card
        assert_no_match date(1.day.ago), card
      end

      test 'Home: a review long ago reads Reviewed by <person> on <date>' do
        @assignment.update_columns(created_at: 400.days.ago, reviewed_at: 200.days.ago, reviewed_by_id: @bo.id)

        get pf('/')

        assert_match ui('assignment.reviewed_by', who: 'Bo Berisha', date: date(200.days.ago)), response.body
      end

      test 'the person page: reviewed by, reviewed on (no person recorded), never reviewed' do
        other = create_permission_set(name: 'Support')
        third = create_permission_set(name: 'Finance')
        create_permission_set_user(user: @ana, permission_set: other).update_columns(reviewed_at: Time.current)
        create_permission_set_user(user: @ana, permission_set: third)
        sign_in(@bo)
        post pf("/assignments/#{@assignment.id}/keep"), params: { reason: 'quarterly review' }

        assert_equal [@bo.id, 'quarterly review'], @assignment.reload.values_at(:reviewed_by_id, :reason)
        get pf("/people/#{@ana.id}")

        today = date(Time.current)
        assert_match ui('assignment.reviewed_by', who: 'Bo Berisha', date: today), response.body
        assert_match ui('assignment.reviewed_on', date: today), response.body
        assert_match ui('assignment.never_reviewed'), response.body
        assert_audit_event('assignment.reviewed', record_id: @assignment.id.to_s, reason: 'quarterly review')
      end

      test 'granted by names the actor of the grant event, not an empty created_by' do
        PermissionForge.with_audit_actor(label: 'ops', type: 'basic_auth') do
          @granted = create_permission_set_user(user: @bo, permission_set: @set)
        end

        get pf("/people/#{@bo.id}")

        assert_nil @granted.created_by_id
        assert_match 'ops (password prompt)', response.body
      end

      # ---- the footer --------------------------------------------------------------

      test 'the footer names the last editor from the events, never a kept one with a newer time' do
        sign_in(@ana)
        patch pf("/permission_sets/#{@set.id}/apply"), params: { pf: { set: { name: 'Sales team' } } }
        PermissionForge.with_audit_actor(label: 'ops', type: 'basic_auth') { @set.reload.update!(description: 'Later') }

        assert_equal @ana.id, @set.reload.updated_by_id
        get pf("/permission_sets/#{@set.id}")

        footer = css_select('.pf-audit-footer').first.text.squish
        assert_match 'Last edited by ops (password prompt)', footer
        assert_no_match 'Last edited by Ana', footer
        assert_select ".pf-audit-footer a[href*='record_type=PermissionForge%3A%3APermissionSet'][href*='record_id=#{@set.id}']"
      end

      test 'without events the footer reads the columns' do
        PermissionForge.configuration.audit_events = false
        @set.update_columns(updated_by_id: @bo.id)

        get pf("/permission_sets/#{@set.id}")

        assert_match 'Last edited by Bo Berisha', css_select('.pf-audit-footer').first.text.squish
      end

      # ---- the person's changes: no silent cap ---------------------------------------

      test 'the person tab says when it shows only the latest records; the CSV has them all' do
        sign_in(@bo)
        3.times { |i| PermissionForge.with_audit_actor(user: @bo) { create_permission_set(name: "Made #{i}") } }
        original = PermissionForge::PeopleController::CHANGES_SHOWN
        PermissionForge::PeopleController.send(:remove_const, :CHANGES_SHOWN)
        PermissionForge::PeopleController.const_set(:CHANGES_SHOWN, 2)

        get pf("/people/#{@bo.id}"), params: { tab: 'audit' }
        assert_match I18n.t('permission_forge.people.audit_tab.made_capped', count: 2), response.body

        get pf("/people/#{@bo.id}.csv")
        assert_equal(3, response.body.lines.count { |line| line.include?('Made ') })
      ensure
        PermissionForge::PeopleController.send(:remove_const, :CHANGES_SHOWN)
        PermissionForge::PeopleController.const_set(:CHANGES_SHOWN, original)
      end

      # ---- reasons -----------------------------------------------------------------

      test 'every change form offers an optional reason, collapsed' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        action = create_resource_action(resource: @resource)
        group = create_permission_set_group(name: 'Ops')
        base = "/permission_sets/#{@set.id}"
        @assignment.update_columns(created_at: 200.days.ago)
        create_permission_set_user(user: @bo, permission_set: @set, expires_at: 3.days.from_now)

        ['/assignments/new', "/assignments/#{@assignment.id}/remove", "#{base}/delete", "#{base}/switch_mode",
         "#{base}/resources/Customer/delete", "#{base}/resources/Customer/actions/#{action.id}/delete",
         "#{base}/resources/Customer/rules/#{rule.id}/delete", "/groups/#{group.id}/delete", "/people/#{@ana.id}/remove_all",
         "#{base}/bulk_assignment/new", "#{base}/bulk_assignment/revoke?user_ids[]=#{@ana.id}", '/', "/people/#{@ana.id}"].each do |path|
          get pf(path)

          assert_select 'details.pf-reason:not([open]) input[name=reason][maxlength="255"]', { minimum: 1 }, path
        end
        post pf("#{base}/review"), params: { pf: { set: { name: 'Renamed' } } }
        assert_select 'form[action$="/apply"] input[name=reason]'
      end

      test 'every other form that changes permission data offers a reason too' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        action = create_resource_action(resource: @resource)
        group = create_permission_set_group(name: 'Ops')
        @set.update!(permission_set_group: group)
        create_resource_field(resource: @resource, name: 'phone', read_access: true, mask_access: false)
        create_permission_set_user(user: @bo, permission_set: @set, expires_at: 3.days.from_now).update_columns(expires_at: 1.day.ago)
        create_permission_set_user(user: @bo, permission_set: create_permission_set(name: 'News', requires_session_flag: 'newsletter'))
        base = "/permission_sets/#{@set.id}"
        resource = "#{base}/resources/Customer"

        {
          "#{resource}/rules/new" => 'form[action$="/rules"]',
          "#{resource}/rules/#{rule.id}/edit" => "form[action$='/rules/#{rule.id}']",
          "#{resource}?tab=rules" => "form[action$='/rules/#{rule.id}/toggle']",
          "#{resource}/actions/new" => 'form[action$="/actions"]',
          "#{resource}/actions/#{action.id}" => "form[action$='/actions/#{action.id}']",
          "#{resource}/fields/email" => 'form[action$="/fields/email"]',
          "#{resource}?tab=fields" => 'form[action$="/sync"]',
          "#{base}?tab=conditions" => 'form[action$="/conditions"]',
          "#{base}?tab=assignments" => "form[action$='/assignments/#{@assignment.id}']",
          '/permission_sets/new' => 'form[action="/permission_forge/permission_sets"][method=post]',
          '/permission_sets' => "form[action$='#{base}/duplicate']",
          base => "form[action$='#{base}/duplicate']",
          "#{base}/resources/new" => "form[action$='#{base}/resources'][method=post]",
          '/groups?new=1' => 'form[action="/permission_forge/groups"][method=post]',
          "/groups/#{group.id}" => "form[action='/permission_forge/groups/#{group.id}']",
          "/groups/#{group.id} " => "form[action$='/groups/#{group.id}/add_set']",
          "/groups/#{group.id}  " => "form[action$='/groups/#{group.id}/remove_set']",
          "/groups/#{group.id}   " => "form[action$='/groups/#{group.id}/duplicate'], button[formaction$='/groups/#{group.id}/duplicate']",
          "/people/#{@bo.id}/consent" => "form[action$='/people/#{@bo.id}/consent'][method=post]",
          "/people/#{@ana.id}/erasure" => "form[action$='/people/#{@ana.id}/erasure']",
          '/?cleanup=1' => 'form[action$="/maintenance/cleanup"]',
          '/?privacy=all' => 'form[action$="/fields/phone/acknowledge"]'
        }.each do |path, form|
          get pf(path.strip)
          assert_response :success, path

          forms = css_select(form).map { |node| node.name == 'button' ? node.ancestors('form').first : node }
          assert forms.any?, "#{path}: no #{form}"
          forms.each do |node|
            inputs = node.css('details.pf-reason:not([open]) input[name=reason][maxlength="255"]')
            assert inputs.any? || css_select("input[name=reason][form='#{node['id']}']").any?, "#{path}: #{form} has no reason field"
          end
        end
      end

      test 'a reason typed on a form that is shown again stays' do
        get pf("/people/#{@ana.id}/erasure")
        post pf("/people/#{@ana.id}/erasure"), params: { confirmation: 'wrong', reason: 'DSR-7' }

        assert_select 'details.pf-reason[open] input[name=reason][value="DSR-7"]'
      end

      test 'a reason given on the forms lands on the events' do
        sign_in(@bo)
        delete pf("/assignments/#{@assignment.id}"), params: { reason: 'left the team' }
        assert_audit_event('assignment.revoked', record_id: @assignment.id.to_s, reason: 'left the team')

        patch pf("/permission_sets/#{@set.id}/apply"), params: { pf: { set: { name: 'Renamed' } }, reason: 'SEC-142' }
        assert_audit_event('permission_set.updated', record_id: @set.id.to_s, reason: 'SEC-142')

        # The group page's Duplicate button posts the header form (its fields are ignored) with its reason.
        group = create_permission_set_group(name: 'Ops')
        post pf("/groups/#{group.id}/duplicate"), params: { _method: 'post', group: { name: 'Ignored', is_active: '0' }, reason: 'SEC-143' }
        cloned = assert_audit_event('permission_set_group.cloned', reason: 'SEC-143')
        assert_equal 'Ops', group.reload.name
        assert_not_equal 'Ignored', cloned.record_label
      end

      # ---- settings and refusals -----------------------------------------------------

      test 'settings: the audit trail label and the assignment hook description' do
        get pf('/settings')

        assert_match 'Record who created and last edited', response.body
        assert_match ':change_expiry', response.body
        assert_match '(controller, target, user_ids, action)', response.body
      end

      test 'an assignment refused in the admin has its own message' do
        PermissionForge.configuration.admin_assignment_authorization = ->(*) { false }

        delete pf("/assignments/#{@assignment.id}")

        assert_equal I18n.t('permission_forge.flash.assignment_not_authorized'), flash[:alert]
        assert_not_equal I18n.t('permission_forge.api.errors.assignment_not_authorized'), flash[:alert]
      end
    end
  end
end
