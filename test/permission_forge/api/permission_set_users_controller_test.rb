# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetUsersControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @user = create_user
      end

      test 'GET index returns users assigned to a permission set' do
        create_permission_set_user(user: @user, permission_set: @ps)

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/users"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['data'].size
        assert_equal @user.id, json['data'].first['user_id']
      end

      test 'POST create assigns a user to a permission set' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal @user.id, json.dig('data', 'user_id')
        assert_equal @ps.id, json.dig('data', 'permission_set_id')
      end

      test 'DELETE destroy removes a user from a permission set' do
        psu = create_permission_set_user(user: @user, permission_set: @ps)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/users/#{psu.uuid}"

        assert_response :no_content
        assert_nil PermissionForge::PermissionSetUser.find_by(id: psu.id)
      end

      # --- Expiration ---

      test 'POST create accepts expires_at' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: {
          user_id: @user.id,
          expires_at: 1.week.from_now.iso8601
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_not_nil json.dig('data', 'expires_at')
      end

      test 'GET index returns expires_at for each assignment' do
        create_permission_set_user(user: @user, permission_set: @ps, expires_at: 1.week.from_now)

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/users"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_not_nil json['data'].first['expires_at']
      end

      test 'POST create with nil expires_at creates permanent assignment' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }

        assert_response :created
        json = JSON.parse(response.body)
        assert_nil json.dig('data', 'expires_at')
      end

      # --- Bulk operations ---

      test 'POST bulk assigns multiple users' do
        user2 = create_user(name: 'User 2')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id, user2.id],
          bulk_action: 'assign'
        }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json.dig('data', 'assigned')
        assert_equal 2, json.dig('data', 'invalidated')
      end

      test 'POST bulk revokes multiple users' do
        user2 = create_user(name: 'User 2')
        create_permission_set_user(user: @user, permission_set: @ps)
        create_permission_set_user(user: user2, permission_set: @ps)

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id, user2.id],
          bulk_action: 'revoke'
        }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json.dig('data', 'revoked')
      end

      test 'POST bulk returns error for invalid action' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users/bulk", params: {
          user_ids: [@user.id],
          bulk_action: 'invalid'
        }

        assert_response :unprocessable_entity
      end
    end
  end
end
