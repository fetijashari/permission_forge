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

      test 'a missing, malformed or unknown user_id is a 422 keyed by user_id, on a group that exists' do
        path = "/permission_forge/api/permission_set_groups/#{@group.uuid}/users"
        errors = 'permission_forge.api.errors'

        { {} => 'user_id_missing', { user_id: 'abc' } => 'user_id_invalid', { user_id: [@user.id] } => 'user_id_invalid',
          { user_id: 99_999 } => 'user_not_found' }.each do |body, key|
          post path, params: body, as: :json

          assert_response :unprocessable_entity, body.inspect
          assert_equal({ 'user_id' => [I18n.t("#{errors}.#{key}")] }, JSON.parse(response.body).dig('error', 'messages'), body.inspect)
        end
        assert_not PermissionForge::PermissionSetGroupUser.exists?(permission_set_group_id: @group.id)
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
