# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class DashboardControllerTest < ActionDispatch::IntegrationTest
      test 'GET /api/stats returns counts' do
        ps = create_permission_set
        create_resource(permission_set: ps)
        user = create_user
        create_permission_set_user(user: user, permission_set: ps)

        get '/permission_forge/api/stats'

        assert_response :ok
        json = JSON.parse(response.body)
        data = json['data']

        assert_equal 1, data['permission_sets_count']
        assert_equal 1, data['active_sets_count']
        assert_equal 1, data['resources_count']
        assert_equal 1, data['users_count']
      end

      test 'GET /api/stats with api_stats_require_admin false returns counts' do
        PermissionForge.configuration.api_stats_require_admin = false
        create_permission_set

        get '/permission_forge/api/stats'
        assert_response :ok
      ensure
        PermissionForge.configuration.api_stats_require_admin = false
      end

      test 'GET /api/stats with api_stats_require_admin true and no admin returns 403' do
        PermissionForge.configuration.api_stats_require_admin = true

        get '/permission_forge/api/stats'
        assert_response :forbidden
      ensure
        PermissionForge.configuration.api_stats_require_admin = false
      end
    end
  end
end
