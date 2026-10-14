require 'test_helper'

module PermissionForge
  module Security
    # Request-level coverage for the 0.10.x hardening pass: mandatory API
    # authorization (#3) and the default-on HTTP Basic Auth wall for the admin UI.
    class HardeningRequestTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set(name: 'Target')
        create_resource(permission_set: @ps, name: 'Customer')
        @user = create_user
      end

      teardown do
        PermissionForge.configuration.api_require_authorization = false
        PermissionForge.configuration.api_action_authorization = nil
        PermissionForge.configuration.api_assignment_authorization = nil
        PermissionForge.configuration.http_basic_auth_enabled = false
        PermissionForge.configuration.http_basic_auth_user = nil
        PermissionForge.configuration.http_basic_auth_password = nil
      end

      # --- #3: api_require_authorization ---------------------------------------

      test 'assignment is allowed when authorization is not required (backward compatible)' do
        PermissionForge.configuration.api_require_authorization = false
        PermissionForge.configuration.api_assignment_authorization = nil

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :created
      end

      test 'assignment is denied (403) when authorization is required but no lambda is set' do
        PermissionForge.configuration.api_require_authorization = true
        PermissionForge.configuration.api_assignment_authorization = nil

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :forbidden
      end

      test 'assignment succeeds when required authorization lambda approves' do
        PermissionForge.configuration.api_require_authorization = true
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { true }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: @user.id }
        assert_response :created
      end

      test 'mutation (clone) is denied (403) when authorization is required but no lambda is set' do
        PermissionForge.configuration.api_require_authorization = true
        PermissionForge.configuration.api_action_authorization = nil

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone", params: { name: 'Cloned' }
        assert_response :forbidden
      end

      # --- Admin UI HTTP Basic Auth (default on) -------------------------------

      test 'admin UI returns 401 when basic auth is enabled but credentials are unset' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.http_basic_auth_user = nil
        PermissionForge.configuration.http_basic_auth_password = nil

        get '/permission_forge/'
        assert_response :unauthorized
      end

      test 'admin UI returns 401 for wrong basic auth credentials' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.http_basic_auth_user = 'admin'
        PermissionForge.configuration.http_basic_auth_password = 's3cret'

        get '/permission_forge/',
            headers: { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'wrong') }
        assert_response :unauthorized
      end

      test 'admin UI allows access with correct basic auth credentials' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.http_basic_auth_user = 'admin'
        PermissionForge.configuration.http_basic_auth_password = 's3cret'

        get '/permission_forge/',
            headers: { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('admin', 's3cret') }
        assert_response :success
      end
    end
  end
end
