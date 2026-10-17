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

      # Field test: per_page=abc or 0 read as 1, a page of one row on a typo.
      test 'a per_page of 0, a negative one or one that is not a number is the default page size' do
        PermissionForge.configuration.api_default_per_page = 4

        [0, -5, '0', '-1', 'abc', '2abc', '1.5', ' ', ''].each do |value|
          get '/permission_forge/api/permission_sets', params: { per_page: value }

          assert_response :ok
          json = JSON.parse(response.body)
          assert_equal 4, json['meta']['pagination']['per_page'], value.inspect
          assert_equal 4, json['data'].size, value.inspect
        end
      ensure
        PermissionForge.configuration.api_default_per_page = 15
      end

      test 'a page that is not a positive whole number is the first page; the max clamp stays' do
        PermissionForge.configuration.api_default_per_page = 3

        [0, -1, 'abc', '2abc'].each do |value|
          get '/permission_forge/api/permission_sets', params: { page: value, per_page: ' 3 ' }

          json = JSON.parse(response.body)
          assert_equal({ 'page' => 1, 'per_page' => 3, 'total_count' => 10 }, json['meta']['pagination'], value.inspect)
        end
        get '/permission_forge/api/permission_sets', params: { page: '9' * 40 }
        assert_equal Api::Pagination::MAX_PAGE, JSON.parse(response.body)['meta']['pagination']['page']
      ensure
        PermissionForge.configuration.api_default_per_page = 15
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
