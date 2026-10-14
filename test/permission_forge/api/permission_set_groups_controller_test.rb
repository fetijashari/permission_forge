# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetGroupsControllerTest < ActionDispatch::IntegrationTest
      test 'GET index returns all groups' do
        create_permission_set_group(name: 'Admins')
        create_permission_set_group(name: 'Editors')

        get '/permission_forge/api/permission_set_groups'

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
      end

      test 'GET show returns a group' do
        group = create_permission_set_group(name: 'Admins')

        get "/permission_forge/api/permission_set_groups/#{group.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'Admins', json.dig('data', 'name')
      end

      test 'POST create creates a group' do
        post '/permission_forge/api/permission_set_groups', params: {
          permission_set_group: { name: 'New Group', description: 'Testing' }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'New Group', json.dig('data', 'name')
      end

      test 'PATCH update modifies a group' do
        group = create_permission_set_group(name: 'Old')

        patch "/permission_forge/api/permission_set_groups/#{group.uuid}", params: {
          permission_set_group: { name: 'Updated' }
        }

        assert_response :ok
        assert_equal 'Updated', group.reload.name
      end

      test 'DELETE destroy removes a group' do
        group = create_permission_set_group

        delete "/permission_forge/api/permission_set_groups/#{group.uuid}"

        assert_response :no_content
      end

      # ---------- CLONE ----------

      test 'POST clone deep-clones permission set group with its permission sets' do
        group = create_permission_set_group(name: 'Original Group')
        ps = create_permission_set(name: 'Set A', permission_set_group: group)
        resource = create_resource(permission_set: ps, name: 'Customer')
        create_resource_field(resource: resource, name: 'email')

        post "/permission_forge/api/permission_set_groups/#{group.uuid}/clone", params: { name: 'Cloned Group' }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'Cloned Group', json.dig('data', 'name')

        cloned = PermissionForge::PermissionSetGroup.find_by(name: 'Cloned Group')
        assert cloned
        assert_equal 1, cloned.permission_sets.count
        assert_equal 1, cloned.permission_sets.first.resources.count
        assert_equal 1, cloned.permission_sets.first.resources.first.resource_fields.count
      end

      test 'POST clone uses default name when no name param given' do
        group = create_permission_set_group(name: 'My Group')

        post "/permission_forge/api/permission_set_groups/#{group.uuid}/clone"

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'My Group (Copy)', json.dig('data', 'name')
      end
    end
  end
end
