# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class BaseControllerTest < ActionDispatch::IntegrationTest
      # ---------- Authentication ----------

      test 'returns 401 when api_auth is nil' do
        original = PermissionForge.configuration.api_auth
        PermissionForge.configuration.api_auth = nil

        get '/permission_forge/api/stats'

        assert_response :unauthorized
      ensure
        PermissionForge.configuration.api_auth = original
      end

      test 'returns 403 when api_auth returns false' do
        original = PermissionForge.configuration.api_auth
        PermissionForge.configuration.api_auth = ->(_controller) { false }

        get '/permission_forge/api/stats'

        assert_response :forbidden
        json = JSON.parse(response.body)
        assert_equal 403, json.dig('error', 'status')
      ensure
        PermissionForge.configuration.api_auth = original
      end

      test 'allows request when api_auth returns true' do
        get '/permission_forge/api/stats'

        assert_response :ok
      end

      # ---------- Error handling ----------

      test 'returns 404 JSON for record not found' do
        get '/permission_forge/api/permission_sets/nonexistent'

        assert_response :not_found
        json = JSON.parse(response.body)
        assert_equal 404, json.dig('error', 'status')
        assert_equal 'Record not found', json.dig('error', 'messages')
      end
    end
  end
end
