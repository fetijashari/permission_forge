# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # API grants, revocations and memberships write their audit events, and
    # config.admin_assignment_authorization is asked after
    # api_assignment_authorization.
    class AssignmentAuditApiTest < ActionDispatch::IntegrationTest
      setup do
        @admin = create_user(name: 'Ada Admin')
        @holder = create_user(name: 'Holder')
        @set = create_permission_set(name: 'Sales rep')
        @group = create_permission_set_group(name: 'Support team')
        @old_resolver = PermissionForge.configuration.current_user_resolver
        admin = @admin
        PermissionForge.configuration.current_user_resolver = -> { admin }
        @calls = []
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      test 'create and destroy record the grant and the revocation with actor and person' do
        post users_path, params: { user_id: @holder.id, expires_at: 10.days.from_now.iso8601, reason: 'TCK-7' }
        assert_response :created
        row = PermissionForge::PermissionSetUser.find_by!(user: @holder, permission_set: @set)
        event = assert_audit_event('assignment.granted', record_id: row.id.to_s, subject_user_id: @holder.id.to_s,
                                                         actor_id: @admin.id.to_s, actor_label: 'Ada Admin', source: 'api',
                                                         reason: 'TCK-7')
        assert event.data['snapshot']['expires_at']

        delete "#{users_path}/#{row.uuid}"
        assert_response :no_content
        assert_audit_event('assignment.revoked', record_id: row.id.to_s, actor_id: @admin.id.to_s)
      end

      test 'a duplicate assignment is a 422 and leaves no event' do
        create_permission_set_user(user: @holder, permission_set: @set)

        assert_no_difference -> { PermissionForge::AuditEvent.count } do
          post users_path, params: { user_id: @holder.id }
        end
        assert_response :unprocessable_entity
      end

      test 'bulk assign and revoke record one event per person under one correlation id' do
        other = create_user(name: 'Other')
        post "#{users_path}/bulk", params: { user_ids: [@holder.id, other.id], bulk_action: 'assign' }
        assert_response :ok
        rows = PermissionForge::PermissionSetUser.where(permission_set: @set).to_a
        granted = rows.map { |row| assert_audit_event('assignment.granted', record_id: row.id.to_s, actor_id: @admin.id.to_s) }
        assert_equal 1, granted.map(&:correlation_id).uniq.size

        post "#{users_path}/bulk", params: { user_ids: [@holder.id, other.id], bulk_action: 'revoke' }
        revoked = rows.map { |row| assert_audit_event('assignment.revoked', record_id: row.id.to_s, actor_id: @admin.id.to_s) }
        assert_equal 1, revoked.map(&:correlation_id).uniq.size
      end

      test 'group members added and removed' do
        post group_users_path, params: { user_id: @holder.id }
        assert_response :created
        membership = PermissionForge::PermissionSetGroupUser.find_by!(user: @holder, permission_set_group: @group)
        assert_audit_event('group_membership.added', record_id: membership.id.to_s, subject_user_id: @holder.id.to_s,
                                                     actor_id: @admin.id.to_s)

        delete "#{group_users_path}/#{membership.uuid}"
        assert_response :no_content
        assert_audit_event('group_membership.removed', record_id: membership.id.to_s, actor_id: @admin.id.to_s)
      end

      test 'a self-assignment refused by admin_assignment_authorization is a 403 with no change, only the refusal recorded' do
        refuse_self
        assert_refusals_only(3) do
          post users_path, params: { user_id: @admin.id }
          assert_response :forbidden
          post "#{users_path}/bulk", params: { user_ids: [@admin.id], bulk_action: 'assign' }
          assert_response :forbidden
          post group_users_path, params: { user_id: @admin.id }
          assert_response :forbidden
        end
        assert_audit_event('api.auth_failed', actor_id: @admin.id.to_s, source: 'api', subject_user_id: @admin.id.to_s,
                                              permission_set_id: @set.id,
                                              data: { 'hook' => 'admin_assignment_authorization', 'action' => 'grant' })
        assert_audit_event('api.auth_failed', record_id: @group.id.to_s, data: { 'action' => 'add_member' })
        assert_not PermissionForge::PermissionSetUser.exists?(user: @admin)
        assert_equal [[@set, [@admin.id], :grant], [@set, [@admin.id], :grant], [@group, [@admin.id], :add_member]], @calls

        post users_path, params: { user_id: @holder.id }
        assert_response :created
      end

      test 'refused revocations and removals are a 403 with no change' do
        row = create_permission_set_user(user: @admin, permission_set: @set)
        membership = PermissionForge::PermissionSetGroupUser.create!(user: @admin, permission_set_group: @group)
        refuse_self

        assert_refusals_only(3) do
          delete "#{users_path}/#{row.uuid}"
          assert_response :forbidden
          post "#{users_path}/bulk", params: { user_ids: [@admin.id.to_s], bulk_action: 'revoke' }
          assert_response :forbidden
          delete "#{group_users_path}/#{membership.uuid}"
          assert_response :forbidden
        end
        assert_equal %i[revoke revoke remove_member], @calls.map(&:last)
        assert PermissionForge::PermissionSetUser.exists?(row.id)
        assert PermissionForge::PermissionSetGroupUser.exists?(membership.id)
      end

      test 'api_assignment_authorization is still asked first' do
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { false }
        refuse_self

        post users_path, params: { user_id: @holder.id }
        assert_response :forbidden
        assert_empty @calls
      end

      test 'an unknown bulk action is a 422 before the service is called' do
        allow_all
        service = PermissionForge::Services::BulkPermissionSetAssignment
        service.singleton_class.alias_method(:pf_kept_call, :call)
        service.define_singleton_method(:call) { |*| raise 'the service must not be called' }
        begin
          ['explode', '', nil].each do |bulk_action|
            post "#{users_path}/bulk", params: { user_ids: [@holder.id], bulk_action: bulk_action }.compact
            assert_response :unprocessable_entity
            assert_match 'Invalid action', JSON.parse(response.body)['error']['messages']
          end
        ensure
          replace_method(service.singleton_class, :call, service.singleton_class.instance_method(:pf_kept_call))
          service.singleton_class.remove_method(:pf_kept_call)
        end
        assert_empty @calls, 'nothing to authorize for an action that does not exist'
      end

      test 'the API bulk actions are exactly the service actions' do
        assert_equal PermissionForge::Services::BulkPermissionSetAssignment::VALID_ACTIONS.map(&:to_s).sort,
                     PermissionForge::Api::PermissionSetUsersController::BULK_ACTIONS.keys.sort
      end

      private

      def users_path
        "/permission_forge/api/permission_sets/#{@set.uuid}/users"
      end

      def group_users_path
        "/permission_forge/api/permission_set_groups/#{@group.uuid}/users"
      end

      def allow_all
        calls = @calls
        PermissionForge.configuration.admin_assignment_authorization = lambda { |_controller, target, user_ids, action|
          calls << [target, user_ids, action]
          true
        }
      end

      # The block changes nothing (no change event) and records `count` refusals.
      def assert_refusals_only(count, &)
        assert_no_difference(-> { PermissionForge::AuditEvent.where(category: 'change').count }) do
          assert_difference(-> { PermissionForge::AuditEvent.where(event: 'api.auth_failed').count }, count, &)
        end
      end

      def refuse_self
        calls = @calls
        admin = @admin
        PermissionForge.configuration.admin_assignment_authorization = lambda { |_controller, target, user_ids, action|
          calls << [target, user_ids, action]
          !user_ids.include?(admin.id)
        }
      end
    end
  end
end
