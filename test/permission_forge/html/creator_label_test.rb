require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Who created a record reads as the audit log names them, everywhere the
    # admin shows it. An HTTP Basic admin stamps no created_by (the column
    # holds a user id), so the footer said "Created by System" and the
    # assignments grid "by System" while the audit log, and the same footer's
    # "Last edited by", named "admin (password prompt)".
    class CreatorLabelTest < AdminTestCase
      setup do
        config = PermissionForge.configuration
        config.audit_trail_enabled = true
        config.http_basic_auth_enabled = true
        config.http_basic_auth_user = 'admin'
        config.http_basic_auth_password = 'secret'
        @old_resolver = config.current_user_resolver
        config.current_user_resolver = -> {}
        @headers = { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'secret') }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      test 'a set and an assignment made by the HTTP Basic admin: footer, grid and audit tab name who the audit log names' do
        post pf('/permission_sets'), params: { type: 'granting', name: 'Finance' }, headers: @headers
        finance = PermissionForge::PermissionSet.find_by!(name: 'Finance')
        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [finance.id], expiry: 'never' }, headers: @headers
        grant = PermissionForge::PermissionSetUser.find_by!(user: @bo, permission_set: finance)

        assert_nil finance.created_by_id, 'the column keeps its meaning: a user id, and the password prompt is none'
        created = assert_audit_event('permission_set.created', record_id: finance.id.to_s, actor_type: 'basic_auth')
        assert_audit_event('assignment.granted', record_id: grant.id.to_s, actor_type: 'basic_auth')
        admin = audit_log_name(created)
        assert_equal 'admin (password prompt)', admin

        get pf("/permission_sets/#{finance.id}"), headers: @headers
        footer = css_select('.pf-audit-footer').first.text.squish
        assert_match "Created by #{admin}", footer
        assert_match "Last edited by #{admin}", footer
        assert_no_match(/System/, footer)

        get pf("/permission_sets/#{finance.id}"), params: { tab: 'assignments' }, headers: @headers
        row = css_select('.pf-table--assignments .pf-table__row').find { |r| r.text.include?('Bo Berisha') }.text.squish
        assert_match "by #{admin}", row

        get pf("/permission_sets/#{finance.id}"), params: { tab: 'audit' }, headers: @headers
        assert_match admin, css_select('.pf-table').map(&:text).join(' ')

        get pf('/audit'), headers: @headers
        assert_match "#{admin} created the Permission Set", response.body.gsub(/<[^>]+>/, '').squish
      end

      test 'the audit trail CSV of a set names the creator from the creation event' do
        post pf('/permission_sets'), params: { type: 'granting', name: 'Finance' }, headers: @headers
        finance = PermissionForge::PermissionSet.find_by!(name: 'Finance')

        get pf("/permission_sets/#{finance.id}.csv"), params: { tab: 'audit' }, headers: @headers

        assert_response :success
        row = response.body.lines.find { |line| line.include?('Finance') }
        assert_equal 2, row.scan('admin (password prompt)').size, row
      end

      test 'a person stamped in created_by, with no event, is still named from the column' do
        PermissionForge.configuration.audit_events = false
        @set.update_columns(created_by_id: @bo.id)

        get pf("/permission_sets/#{@set.id}"), headers: @headers

        assert_match 'Created by Bo Berisha', css_select('.pf-audit-footer').first.text.squish
      end

      test 'a person who created the record is named by both' do
        PermissionForge.with_audit_actor(user: @bo) { @made = create_permission_set(name: 'Made by Bo') }

        assert_equal @bo.id, @made.created_by_id
        get pf("/permission_sets/#{@made.id}"), headers: @headers

        assert_match 'Created by Bo Berisha', css_select('.pf-audit-footer').first.text.squish
      end

      private

      def audit_log_name(event)
        ApplicationController.helpers.extend(PermissionForge::ApplicationHelper).pf_audit_actor_name(event)
      end
    end
  end
end
