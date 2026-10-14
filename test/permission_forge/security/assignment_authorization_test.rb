# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class AssignmentAuthorizationTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @user = create_user
      end

      teardown do
        PermissionForge.configuration.api_assignment_authorization = nil
      end

      # --- Single assignment ---

      test 'create succeeds when api_assignment_authorization is nil' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :created
      end

      test 'create succeeds when authorizer returns true' do
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { true }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :created
      end

      test 'create returns 403 when authorizer returns false' do
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { false }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :forbidden
        json = JSON.parse(response.body)
        assert json['error']['messages'].present?
      end

      test 'create authorizer receives correct permission_set and user_ids' do
        received = {}
        PermissionForge.configuration.api_assignment_authorization = lambda { |_c, ps, user_ids|
          received[:ps] = ps
          received[:user_ids] = user_ids
          true
        }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_equal @ps.id, received[:ps].id
        assert_equal [@user.id.to_s], received[:user_ids].map(&:to_s)
      end

      # --- Bulk assignment ---

      test 'bulk succeeds when api_assignment_authorization is nil' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id], bulk_action: 'assign'
        }
        assert_response :ok
      end

      test 'bulk returns 403 when authorizer returns false' do
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { false }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id], bulk_action: 'assign'
        }
        assert_response :forbidden
      end
    end
  end
end
