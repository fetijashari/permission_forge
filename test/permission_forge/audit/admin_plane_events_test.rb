# frozen_string_literal: true

require 'test_helper'
require_relative 'request_audit_test_helper'

module PermissionForge
  module Audit
    # Refusals of the admin plane: failed sign-ins (HTTP Basic, API), denied
    # API authorization and locked records. Never a submitted password, and
    # never lost to a transaction that rolls back.
    class AdminPlaneEventsTest < ActionDispatch::IntegrationTest
      include RequestAuditTestHelper

      setup do
        @set = create_permission_set(name: 'Sales rep')
      end

      # ---- HTTP Basic --------------------------------------------------------------

      test 'wrong Basic credentials record admin.auth_failed with the supplied username, never the password' do
        enable_basic_auth(user: 'ops-admin', password: 's3cret-pass')

        assert_difference -> { audit_events_for('admin.auth_failed').count }, 1 do
          get "#{ROOT}/people", headers: basic_auth_header('mallory', 'hunter2-guess').merge('REMOTE_ADDR' => '10.6.6.6')
        end

        assert_response :unauthorized
        event = assert_audit_event('admin.auth_failed', actor_type: 'basic_auth', actor_id: nil, actor_label: 'mallory',
                                                        source: 'admin_ui', category: 'admin', ip: '10.6.6.6',
                                                        data: { 'reason' => 'invalid_credentials' })
        refute_includes event.attributes.to_json, 'hunter2-guess'
        refute_includes event.attributes.to_json, 's3cret-pass'
      end

      test 'the right username with a wrong password is still a failure, and stores no password' do
        enable_basic_auth(user: 'ops-admin', password: 's3cret-pass')

        get "#{ROOT}/people", headers: basic_auth_header('ops-admin', 's3cret-pasX')

        assert_response :unauthorized
        event = assert_audit_event('admin.auth_failed', actor_label: 'ops-admin')
        refute_includes event.attributes.to_json, 's3cret-pas'
      end

      test 'a browser challenge without credentials is not a failure' do
        enable_basic_auth

        assert_no_difference(-> { audit_events_for('admin.auth_failed').count }) { get "#{ROOT}/people" }
        assert_response :unauthorized
      end

      test 'credentials sent while Basic auth is enabled but not configured are recorded' do
        PermissionForge.configuration.http_basic_auth_enabled = true

        get "#{ROOT}/people", headers: basic_auth_header('someone', 'pw')

        assert_response :unauthorized
        assert_audit_event('admin.auth_failed', actor_label: 'someone', data: { 'reason' => 'basic_auth_not_configured' })
      end

      test 'a supplied username is capped at 255 characters' do
        enable_basic_auth

        get "#{ROOT}/people", headers: basic_auth_header('u' * 600, 'pw')

        assert_equal 255, assert_audit_event('admin.auth_failed').actor_label.length
      end

      test 'right credentials record no failure' do
        enable_basic_auth

        assert_no_difference(-> { audit_events_for('admin.auth_failed').count }) do
          get "#{ROOT}/people", headers: basic_auth_header('ops-admin', 's3cret-pass')
        end
        assert_response :ok
      end

      # ---- API authentication / authorization ---------------------------------------

      test 'an API request without api_auth configured records api.auth_failed (401)' do
        PermissionForge.configuration.api_auth = nil

        get "#{ROOT}/api/permission_sets", headers: { 'REMOTE_ADDR' => '10.7.7.7' }

        assert_response :unauthorized
        assert_audit_event('api.auth_failed', source: 'api', ip: '10.7.7.7', actor_type: 'unknown',
                                              data: { 'reason' => 'api_auth_not_configured', 'status' => 401 })
      end

      test 'an API request api_auth refuses records api.auth_failed (403) with who the host knows' do
        admin = create_user(name: 'Ada Admin')
        sign_in(admin)
        PermissionForge.configuration.api_auth = ->(_c) { false }

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'x' } }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', actor_type: 'user', actor_id: admin.id.to_s,
                                              data: { 'reason' => 'api_auth_denied', 'status' => 403, 'method' => 'POST' })
        assert_nil PermissionForge::PermissionSet.find_by(name: 'x')
      end

      test 'an API mutation refused by api_action_authorization records api.auth_failed' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _action, _record) { false }

        delete "#{ROOT}/api/permission_sets/#{@set.uuid}"

        assert_response :forbidden
        assert_audit_event('api.auth_failed', record_id: @set.id.to_s, permission_set_id: @set.id,
                                              data: { 'reason' => 'action_not_authorized', 'action' => 'destroy' })
      end

      test 'an API mutation refused because no authorization lambda is set records api.auth_failed' do
        PermissionForge.configuration.api_require_authorization = true

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'x' } }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', data: { 'reason' => 'action_not_authorized', 'action' => 'create' })
      end

      test 'an API assignment refused by api_assignment_authorization records api.auth_failed' do
        user = create_user
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _set, _ids) { false }

        post "#{ROOT}/api/permission_sets/#{@set.uuid}/users", params: { user_id: user.id }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', permission_set_id: @set.id, subject_user_id: user.id.to_s,
                                              data: { 'reason' => 'assignment_not_authorized', 'user_ids' => [user.id.to_s] })
        assert_empty @set.permission_set_users.where(user_id: user.id).to_a
      end

      # ---- locked records ------------------------------------------------------------

      test 'the HTML refusal of a locked record records admin.lock_refused' do
        @set.update_columns(is_editable: false)
        admin = create_user(name: 'Ada Admin')
        sign_in(admin)

        delete "#{ROOT}/permission_sets/#{@set.id}"

        assert_equal I18n.t('permission_forge.flash.not_editable'), flash[:alert]
        assert_audit_event('admin.lock_refused', record_id: @set.id.to_s, permission_set_id: @set.id, actor_id: admin.id.to_s,
                                                 source: 'admin_ui',
                                                 data: { 'endpoint' => 'permission_forge/permission_sets#destroy', 'method' => 'DELETE' })
      end

      test 'the API refusal of a locked record records admin.lock_refused' do
        @set.update_columns(is_editable: false)

        patch "#{ROOT}/api/permission_sets/#{@set.uuid}", params: { permission_set: { name: 'x' }, reason: 'try anyway' }

        assert_response :forbidden
        assert_audit_event('admin.lock_refused', record_id: @set.id.to_s, source: 'api', reason: 'try anyway',
                                                 data: { 'endpoint' => 'permission_forge/api/permission_sets#update' })
      end

      test 'an unlocked record records no refusal' do
        assert_no_difference(-> { audit_events_for('admin.lock_refused').count }) do
          rename_set(@set, 'Fine')
        end
      end

      # ---- review round 1 ---------------------------------------------------------------

      SPOOF_HEADERS = { 'X-Forwarded-For' => '6.6.6.6', 'Client-IP' => '7.7.7.7', 'REMOTE_ADDR' => '10.4.4.4' }.freeze

      test 'contradicting Client-IP / X-Forwarded-For: a failed Basic login is still recorded, with the peer address' do
        enable_basic_auth(user: 'ops-admin', password: 's3cret-pass')

        with_quiet_request_log do
          assert_difference(-> { audit_events_for('admin.auth_failed').count }, 1) do
            get "#{ROOT}/people", headers: basic_auth_header('ops-admin', 'guess').merge(SPOOF_HEADERS)
          end
          assert_response :unauthorized

          get "#{ROOT}/people", headers: basic_auth_header('ops-admin', 's3cret-pass').merge(SPOOF_HEADERS)
          assert_response :ok, 'the right password is not told apart by a 500'
        end
        assert_audit_event('admin.auth_failed', ip: '10.4.4.4', data: { 'reason' => 'invalid_credentials', 'ip_spoof_suspected' => true })
      end

      test 'contradicting forwarding headers: a refused API request is still recorded' do
        PermissionForge.configuration.api_auth = ->(_c) { false }

        with_quiet_request_log { get "#{ROOT}/api/permission_sets", headers: SPOOF_HEADERS }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', ip: '10.4.4.4', data: { 'reason' => 'api_auth_denied', 'ip_spoof_suspected' => true })
      end

      test 'a typed username with line breaks and terminal escapes is stored on one clean line' do
        enable_basic_auth

        get "#{ROOT}/people", headers: basic_auth_header("mal\nlory\r\e[31m", 'pw')

        assert_audit_event('admin.auth_failed', actor_label: 'mal lory [31m')
      end

      test 'refused API assignments store bounded ids: scalars only, each capped, at most 100 listed' do
        PermissionForge.configuration.api_assignment_authorization = ->(*) { false }

        post "#{ROOT}/api/permission_sets/#{@set.uuid}/users", params: { user_id: 'u' * 5000 }
        assert_response :forbidden
        single = assert_audit_event('api.auth_failed', data: { 'reason' => 'assignment_not_authorized', 'user_count' => 1 })
        assert_equal 255, single.subject_user_id.length
        assert_equal [255], single.data['user_ids'].map(&:length)

        post "#{ROOT}/api/permission_sets/#{@set.uuid}/users/bulk", params: { user_ids: Array.new(150) { |i| "#{i}#{'v' * 2000}" },
                                                                              bulk_action: 'assign' }
        assert_response :forbidden
        bulk = assert_audit_event('api.auth_failed', data: { 'user_count' => 150 })
        assert_equal 100, bulk.data['user_ids'].size
        assert(bulk.data['user_ids'].all? { |id| id.length <= 255 })
        assert_nil bulk.subject_user_id

        post "#{ROOT}/api/permission_sets/#{@set.uuid}/users/bulk", params: { user_ids: { 'a' => { 'b' => 'c' } }, bulk_action: 'assign' }
        assert_audit_event('api.auth_failed', data: { 'user_ids' => [], 'user_count' => 0 })
      end

      test 'the HTML refusal of admin_assignment_authorization records admin.auth_failed' do
        admin = create_user(name: 'Ada Admin')
        person = create_user(name: 'Bo')
        sign_in(admin)
        PermissionForge.configuration.admin_assignment_authorization = ->(*) { false }

        assert_no_difference(-> { PermissionForge::PermissionSetUser.count }) do
          post "#{ROOT}/assignments", params: { user_id: person.id, set_ids: [@set.id], expiry: 'never', reason: 'please' }
        end

        assert_audit_event('admin.auth_failed', actor_id: admin.id.to_s, source: 'admin_ui', permission_set_id: @set.id,
                                                subject_user_id: person.id.to_s, reason: 'please',
                                                data: { 'reason' => 'assignment_not_authorized', 'hook' => 'admin_assignment_authorization',
                                                        'action' => 'grant', 'user_ids' => [person.id.to_s] })
      end

      test 'the API refusal of admin_assignment_authorization records api.auth_failed' do
        person = create_user(name: 'Bo')
        PermissionForge.configuration.admin_assignment_authorization = ->(*) { false }

        post "#{ROOT}/api/permission_sets/#{@set.uuid}/users", params: { user_id: person.id }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', source: 'api', permission_set_id: @set.id, subject_user_id: person.id.to_s,
                                              data: { 'hook' => 'admin_assignment_authorization', 'action' => 'grant' })
      end

      test 'a group membership refusal names the group as the record, not as a Permission Set' do
        group = create_permission_set_group(name: 'Ops')
        person = create_user(name: 'Bo')
        PermissionForge.configuration.admin_assignment_authorization = ->(*) { false }

        post "#{ROOT}/api/permission_set_groups/#{group.uuid}/users", params: { user_id: person.id }

        assert_response :forbidden
        assert_audit_event('api.auth_failed', record_type: 'PermissionForge::PermissionSetGroup', record_id: group.id.to_s,
                                              permission_set_id: nil, data: { 'action' => 'add_member' })
      end

      test 'reading the audit log through the API without audit_log_authorization records api.auth_failed' do
        PermissionForge.configuration.audit_log_authorization = ->(_c) { false }

        get "#{ROOT}/api/audit_events"

        assert_response :forbidden
        assert_audit_event('api.auth_failed', data: { 'reason' => 'audit_log_not_authorized' })
        assert_empty audit_events_for('audit.viewed').to_a
      end
    end
  end
end
