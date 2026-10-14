# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetGroupUsersControllerTest < ActionDispatch::IntegrationTest
      setup do
        @group = create_permission_set_group
        @user = create_user
      end

      test 'GET index returns users in a group' do
        PermissionForge::PermissionSetGroupUser.create!(
          uuid: SecureRandom.uuid,
          permission_set_group: @group,
          user: @user
        )

        get "/permission_forge/api/permission_set_groups/#{@group.uuid}/users"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['data'].size
      end

      test 'POST create adds a user to a group' do
        post "/permission_forge/api/permission_set_groups/#{@group.uuid}/users", params: { user_id: @user.id }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal @user.id, json.dig('data', 'user_id')
      end

      test 'DELETE destroy removes a user from a group' do
        gu = PermissionForge::PermissionSetGroupUser.create!(
          uuid: SecureRandom.uuid,
          permission_set_group: @group,
          user: @user
        )

        delete "/permission_forge/api/permission_set_groups/#{@group.uuid}/users/#{gu.uuid}"

        assert_response :no_content
      end
    end
  end
end
