# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class PaginationLimitsTest < ActionDispatch::IntegrationTest
      setup do
        10.times { |i| create_permission_set(name: "Set #{i}") }
      end

      # --- Default pagination (no custom handler) ---

      test 'collection endpoints return paginated results by default' do
        get '/permission_forge/api/permission_sets'

        assert_response :ok
        json = JSON.parse(response.body)
        assert json.key?('meta'), 'response should include meta'
        assert json['meta'].key?('pagination'), 'meta should include pagination'
        assert_equal 1, json['meta']['pagination']['page']
        assert_equal 10, json['meta']['pagination']['total_count']
      end

      test 'per_page is clamped to api_max_per_page' do
        PermissionForge.configuration.api_max_per_page = 5

        get '/permission_forge/api/permission_sets', params: { per_page: 999_999 }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 5, json['data'].size
        assert_equal 5, json['meta']['pagination']['per_page']
      ensure
        PermissionForge.configuration.api_max_per_page = 100
      end

      test 'per_page of 0 is clamped to 1' do
        get '/permission_forge/api/permission_sets', params: { per_page: 0 }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['meta']['pagination']['per_page']
        assert_equal 1, json['data'].size
      end

      test 'negative per_page is clamped to 1' do
        get '/permission_forge/api/permission_sets', params: { per_page: -5 }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['meta']['pagination']['per_page']
      end

      test 'default per_page uses api_default_per_page config' do
        PermissionForge.configuration.api_default_per_page = 3

        get '/permission_forge/api/permission_sets'

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 3, json['meta']['pagination']['per_page']
        assert_equal 3, json['data'].size
      ensure
        PermissionForge.configuration.api_default_per_page = 15
      end

      test 'page parameter works with default paginator' do
        PermissionForge.configuration.api_default_per_page = 3

        get '/permission_forge/api/permission_sets', params: { page: 2 }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['meta']['pagination']['page']
        assert_equal 3, json['data'].size
      ensure
        PermissionForge.configuration.api_default_per_page = 15
      end

      test 'api_max_per_page config is respected' do
        PermissionForge.configuration.api_max_per_page = 2

        get '/permission_forge/api/permission_sets'

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
        assert_equal 10, json['meta']['pagination']['total_count']
      ensure
        PermissionForge.configuration.api_max_per_page = 100
      end

      # --- Custom pagination handler ---

      test 'custom pagination handler still clamps per_page' do
        PermissionForge.configuration.api_max_per_page = 3
        PermissionForge.configuration.api_pagination_handler = lambda { |scope, page, per_page|
          records = scope.limit(per_page).offset((page - 1) * per_page)
          records.define_singleton_method(:total_count) { scope.count }
          records
        }

        get '/permission_forge/api/permission_sets', params: { per_page: 999 }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 3, json['data'].size
      ensure
        PermissionForge.configuration.api_max_per_page = 100
        PermissionForge.configuration.api_pagination_handler = nil
      end
    end
  end
end
