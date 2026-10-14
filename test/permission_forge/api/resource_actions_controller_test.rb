# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class ResourceActionsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer')
      end

      test 'GET index returns actions for a resource' do
        create_resource_action(resource: @resource, name: 'export')
        create_resource_action(resource: @resource, name: 'archive')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
      end

      test 'POST create creates a resource action' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions", params: {
          resource_action: { name: 'export', label: 'Export', is_permitted: true }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'export', json.dig('data', 'name')
        assert json.dig('data', 'is_permitted')
      end

      test 'POST create with a name the resource already has is a 422, not a second row' do
        create_resource_action(resource: @resource, name: 'export')

        assert_no_difference 'PermissionForge::ResourceAction.count' do
          post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions", params: {
            resource_action: { name: 'export', is_permitted: true }
          }
        end

        assert_response :unprocessable_entity
        assert_equal ['This resource already has an action with that name.'],
                     JSON.parse(response.body).dig('error', 'messages', 'name')
      end

      test 'PATCH update onto a name the resource already has is a 422' do
        create_resource_action(resource: @resource, name: 'export')
        sync = create_resource_action(resource: @resource, name: 'sync')

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions/#{sync.uuid}", params: {
          resource_action: { name: 'export' }
        }

        assert_response :unprocessable_entity
        assert_equal 'sync', sync.reload.name
      end

      test 'PATCH update modifies an action' do
        action = create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions/#{action.uuid}", params: {
          resource_action: { is_permitted: true }
        }

        assert_response :ok
        assert action.reload.is_permitted
      end

      test 'DELETE destroy removes an action' do
        action = create_resource_action(resource: @resource)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions/#{action.uuid}"

        assert_response :no_content
      end

      # --- action names (PermissionForge::ControllerActions::KEY_FORMAT) -----------
      #
      # A name that is not an action key ("Export", "archive ") would look like a
      # restriction in the admin while `export` / `archive` stay unmanaged.

      def actions_path
        "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/actions"
      end

      def assert_name_rejected
        assert_response :unprocessable_entity
        error = JSON.parse(response.body).fetch('error')

        assert_equal 422, error['status']
        assert_equal [I18n.t('permission_forge.errors.admin.action_format')], error.dig('messages', 'name')
      end

      test 'POST create rejects a name that is not a valid action key' do
        ['Export', 'archive ', 'export-csv', '1st', '', "export\n", 'a' * 64].each do |name|
          post actions_path, params: { resource_action: { name: name, is_permitted: false } }

          assert_name_rejected
        end
        post actions_path, params: { resource_action: { label: 'No name' } }

        assert_name_rejected
        assert_empty @resource.resource_actions.reload
      end

      test 'POST create accepts every valid action key' do
        ['export', 'export_csv', 'sync2', 'a' * 63].each do |name|
          post actions_path, params: { resource_action: { name: name } }

          assert_response :created, name
        end
      end

      test 'PATCH update rejects renaming an action to an invalid key' do
        action = create_resource_action(resource: @resource, name: 'export', label: 'Export')

        patch "#{actions_path}/#{action.uuid}", params: { resource_action: { name: 'Export', label: 'Changed' } }

        assert_name_rejected
        assert_equal %w[export Export], action.reload.values_at(:name, :label)
      end

      test 'PATCH update renames an action to another valid key' do
        action = create_resource_action(resource: @resource, name: 'export')

        patch "#{actions_path}/#{action.uuid}", params: { resource_action: { name: 'export_csv' } }

        assert_response :ok
        assert_equal 'export_csv', action.reload.name
      end

      test 'PATCH update still edits a legacy row whose name is not a valid key, unless it renames it badly' do
        legacy = create_resource_action(resource: @resource, name: 'LegacyExport', is_permitted: false)

        patch "#{actions_path}/#{legacy.uuid}", params: { resource_action: { is_permitted: true } }
        assert_response :ok

        patch "#{actions_path}/#{legacy.uuid}", params: { resource_action: { name: 'LegacyExport', label: 'Legacy' } }
        assert_response :ok
        assert_equal ['LegacyExport', 'Legacy', true], legacy.reload.values_at(:name, :label, :is_permitted)

        patch "#{actions_path}/#{legacy.uuid}", params: { resource_action: { name: 'Legacy Export' } }
        assert_name_rejected

        patch "#{actions_path}/#{legacy.uuid}", params: { resource_action: { name: 'legacy_export' } }
        assert_response :ok
        assert_equal 'legacy_export', legacy.reload.name
      end

      test 'the name error is translated' do
        post actions_path, params: { resource_action: { name: 'Export' }, locale: 'sq' }

        assert_response :unprocessable_entity
        assert_equal [I18n.t('permission_forge.errors.admin.action_format', locale: :sq)],
                     JSON.parse(response.body).dig('error', 'messages', 'name')
      end

      test 'authorization is checked before the name' do
        PermissionForge.configuration.api_action_authorization = ->(_controller, _action, _record) { false }
        post actions_path, params: { resource_action: { name: 'Export' } }
        assert_response :forbidden

        action = create_resource_action(resource: @resource, name: 'export')
        patch "#{actions_path}/#{action.uuid}", params: { resource_action: { name: 'Export' } }
        assert_response :forbidden
      end

      test 'a legacy action name survives cloning its Permission Set' do
        create_resource_action(resource: @resource, name: 'LegacyExport', is_permitted: true)

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone", params: { name: 'Cloned' }

        assert_response :created
        cloned = PermissionForge::PermissionSet.find_by!(name: 'Cloned')
        assert_equal ['LegacyExport'], cloned.resources.first.resource_actions.map(&:name)
      end
    end
  end
end
