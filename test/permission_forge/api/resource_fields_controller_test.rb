# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class ResourceFieldsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer')
      end

      test 'GET index returns fields for a resource' do
        create_resource_field(resource: @resource, name: 'email')
        create_resource_field(resource: @resource, name: 'phone')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/fields"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
      end

      test 'GET show returns a single field with mask attributes' do
        field = create_resource_field(resource: @resource, name: 'email', mask_access: true, mask_strategy: 'email')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/fields/#{field.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'email', json.dig('data', 'name')
        assert json.dig('data', 'mask_access')
        assert_equal 'email', json.dig('data', 'mask_strategy')
      end

      test 'POST create creates a field with mask attributes' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/fields", params: {
          resource_field: {
            name: 'ssn', label: 'SSN', read_access: true, edit_access: false,
            mask_access: true, mask_strategy: 'last4'
          }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'ssn', json.dig('data', 'name')
        assert json.dig('data', 'mask_access')
        assert_equal 'last4', json.dig('data', 'mask_strategy')
      end

      test 'PATCH update modifies mask settings' do
        field = create_resource_field(resource: @resource, name: 'email', mask_access: false)

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/fields/#{field.uuid}", params: {
          resource_field: { mask_access: true, mask_strategy: 'email' }
        }

        assert_response :ok
        field.reload
        assert field.mask_access
        assert_equal 'email', field.mask_strategy
      end

      test 'DELETE destroy removes a field' do
        field = create_resource_field(resource: @resource)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/fields/#{field.uuid}"

        assert_response :no_content
      end
    end
  end
end
