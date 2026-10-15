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

      test 'returns 401 when api_auth returns false' do
        original = PermissionForge.configuration.api_auth
        PermissionForge.configuration.api_auth = ->(_controller) { false }

        get '/permission_forge/api/stats'

        assert_response :unauthorized
        json = JSON.parse(response.body)
        assert_equal 401, json.dig('error', 'status')
      ensure
        PermissionForge.configuration.api_auth = original
      end

      test 'a WWW-Authenticate challenge set by api_auth is sent with the 401; none is invented' do
        original = PermissionForge.configuration.api_auth
        PermissionForge.configuration.api_auth = ->(_controller) { false }
        get '/permission_forge/api/permission_sets'
        assert_response :unauthorized
        assert_nil response.headers['WWW-Authenticate']
        assert_equal I18n.t('permission_forge.api.errors.unauthorized', locale: :en), response.parsed_body.dig('error', 'messages')

        PermissionForge.configuration.api_auth = lambda { |controller|
          controller.response.headers['WWW-Authenticate'] = 'Bearer realm="permissions"'
          false
        }
        get '/permission_forge/api/permission_sets'
        assert_response :unauthorized
        assert_equal 'Bearer realm="permissions"', response.headers['WWW-Authenticate']
      ensure
        PermissionForge.configuration.api_auth = original
      end

      # 403 is for an authenticated caller: the message says whether a lambda
      # refused or one is missing (the integrator's fix), never the same text.
      test 'a mutation refused because an authorization lambda is unset says which option is missing' do
        config = PermissionForge.configuration
        previous = [config.api_action_authorization, config.api_assignment_authorization, config.api_require_authorization]
        config.api_action_authorization = nil
        config.api_assignment_authorization = nil
        config.api_require_authorization = true
        set = create_permission_set(name: 'Lambdas')

        post '/permission_forge/api/permission_sets', params: { permission_set: { name: 'x' } }
        assert_response :forbidden
        assert_equal I18n.t('permission_forge.api.errors.action_authorization_missing', locale: :en),
                     response.parsed_body.dig('error', 'messages')
        assert_match 'config.api_action_authorization', response.parsed_body.dig('error', 'messages')

        post "/permission_forge/api/permission_sets/#{set.uuid}/users", params: { user_id: create_user.id }
        assert_response :forbidden
        assert_match 'config.api_assignment_authorization', response.parsed_body.dig('error', 'messages')

        config.api_action_authorization = ->(*) { false }
        config.api_assignment_authorization = ->(*) { false }
        post '/permission_forge/api/permission_sets', params: { permission_set: { name: 'x' } }
        assert_equal I18n.t('permission_forge.api.errors.action_not_authorized', locale: :en), response.parsed_body.dig('error', 'messages')
        post "/permission_forge/api/permission_sets/#{set.uuid}/users", params: { user_id: create_user.id }
        assert_equal I18n.t('permission_forge.api.errors.assignment_not_authorized', locale: :en),
                     response.parsed_body.dig('error', 'messages')
      ensure
        config.api_action_authorization, config.api_assignment_authorization, config.api_require_authorization = previous
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
