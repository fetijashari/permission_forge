# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class ResourcesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
      end

      test 'GET index returns resources for a permission set' do
        create_resource(permission_set: @ps, name: 'Customer')
        create_resource(permission_set: @ps, name: 'Supplier')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
      end

      test 'GET show returns a single resource' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'Customer', json.dig('data', 'name')
        assert json.dig('data', 'read_access')
      end

      test 'POST create creates a resource' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Article', read_access: true, create_access: false, edit_access: true, delete_access: false }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'Article', json.dig('data', 'name')
        assert json.dig('data', 'read_access')
        assert json.dig('data', 'edit_access')
        refute json.dig('data', 'create_access')
      end

      test 'PATCH update modifies a resource' do
        resource = create_resource(permission_set: @ps, name: 'Customer', edit_access: false)

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}", params: {
          resource: { edit_access: true }
        }

        assert_response :ok
        assert resource.reload.edit_access
      end

      test 'DELETE destroy removes a resource' do
        resource = create_resource(permission_set: @ps)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}"

        assert_response :no_content
        assert_nil PermissionForge::Resource.find_by(id: resource.id)
      end

      test 'POST create with view_all and modify_all' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Project', read_access: true, view_all: true, modify_all: true }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert json.dig('data', 'view_all')
        assert json.dig('data', 'modify_all')
      end

      test 'PATCH update view_all and modify_all' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}", params: {
          resource: { view_all: true, modify_all: true }
        }

        assert_response :ok
        resource.reload
        assert resource.view_all
        assert resource.modify_all
      end

      test 'POST create rejects edit_access without read_access' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Bad', read_access: false, edit_access: true }
        }

        assert_response :unprocessable_entity
      end

      test 'POST generate_fields auto-generates fields' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields",
             params: { grant_all: 'true' }

        assert_response :created
        json = JSON.parse(response.body)
        assert json['data'].is_a?(Array)
        assert json['data'].size.positive?
      end
    end
  end
end
