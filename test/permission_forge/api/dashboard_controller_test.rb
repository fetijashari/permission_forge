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

      test 'GET /api/stats with api_stats_require_admin true and no api_stats_authorization is a 403 that names it' do
        PermissionForge.configuration.api_stats_require_admin = true

        assert_difference -> { PermissionForge::AuditEvent.unscoped.where(event: 'api.auth_failed').count }, 1 do
          get '/permission_forge/api/stats'
        end
        assert_response :forbidden
        assert_equal I18n.t('permission_forge.api.errors.stats_authorization_missing', locale: :en),
                     response.parsed_body.dig('error', 'messages')
        assert_audit_event('api.auth_failed', data: { 'reason' => 'stats_not_authorized', 'hook' => 'api_stats_require_admin' })
      end

      test 'api_stats_authorization decides who reads the stats' do
        config = PermissionForge.configuration
        config.api_stats_require_admin = true
        seen = []
        config.api_stats_authorization = lambda { |controller|
          seen << controller.class
          controller.request.headers['X-Stats'] == 'yes'
        }

        get '/permission_forge/api/stats', headers: { 'X-Stats' => 'yes' }
        assert_response :ok
        assert_equal [PermissionForge::Api::DashboardController], seen

        get '/permission_forge/api/stats'
        assert_response :forbidden
        assert_equal I18n.t('permission_forge.api.errors.forbidden', locale: :en), response.parsed_body.dig('error', 'messages')
        assert_audit_event('api.auth_failed', data: { 'reason' => 'stats_not_authorized', 'hook' => 'api_stats_authorization' })
      end

      test 'api_stats_require_admin false ignores api_stats_authorization' do
        PermissionForge.configuration.api_stats_authorization = ->(_controller) { false }

        get '/permission_forge/api/stats'
        assert_response :ok
      end

      # Documented in 0.14: api_auth set @admin = true on the controller.
      # Kept through 0.15 with a deprecation warning; removed in 0.16.
      test 'an @admin set by api_auth still allows the stats, with a deprecation warning' do
        config = PermissionForge.configuration
        config.api_stats_require_admin = true
        config.api_auth = lambda { |controller|
          controller.instance_variable_set(:@admin, true)
          true
        }
        warnings = []
        deprecator = PermissionForge.deprecator
        saved = deprecator.behavior
        deprecator.behavior = ->(message, *) { warnings << message }
        PermissionForge::Deprecation.reset!

        get '/permission_forge/api/stats'

        assert_response :ok
        assert_equal 1, warnings.size
        assert_match 'config.api_stats_authorization', warnings.first
      ensure
        deprecator.behavior = saved if deprecator
        PermissionForge::Deprecation.reset!
      end

      test 'with api_stats_authorization set, @admin no longer decides' do
        config = PermissionForge.configuration
        config.api_stats_require_admin = true
        config.api_stats_authorization = ->(_controller) { false }
        config.api_auth = lambda { |controller|
          controller.instance_variable_set(:@admin, true)
          true
        }

        get '/permission_forge/api/stats'
        assert_response :forbidden
      end
    end
  end
end
