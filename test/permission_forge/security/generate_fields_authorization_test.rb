require 'test_helper'

module PermissionForge
  module Security
    # POST .../generate_fields grants read (and, with grant_all, edit) on every
    # unconfigured column of a resource. It is a mutation, so it must pass the
    # same gates as the admin UI's "Sync fields": the authorization hook, then
    # the lock on the resource and on its permission set.
    class GenerateFieldsAuthorizationTest < ActionDispatch::IntegrationTest
      setup do
        @set = create_permission_set(name: 'Target')
        @resource = create_resource(permission_set: @set, name: 'Customer')
      end

      teardown do
        PermissionForge.configuration.api_require_authorization = false
        PermissionForge.configuration.api_action_authorization = nil
      end

      test 'generates fields when nothing forbids it (backward compatible)' do
        generate_fields

        assert_response :created
        assert_operator @resource.resource_fields.count, :>, 0
      end

      test 'is denied when authorization is required but no hook is set' do
        PermissionForge.configuration.api_require_authorization = true

        generate_fields

        assert_response :forbidden
        assert_equal 0, @resource.resource_fields.count
      end

      test 'is denied when the hook refuses, and the hook sees the action and the resource' do
        seen = nil
        PermissionForge.configuration.api_action_authorization = lambda { |_controller, action, record|
          seen = [action, record]
          false
        }

        generate_fields

        assert_response :forbidden
        assert_equal [:generate_fields, @resource], seen
        assert_equal 0, @resource.resource_fields.count
      end

      test 'is allowed when the hook approves' do
        PermissionForge.configuration.api_require_authorization = true
        PermissionForge.configuration.api_action_authorization = ->(_controller, _action, _record) { true }

        generate_fields

        assert_response :created
        assert_operator @resource.resource_fields.count, :>, 0
      end

      test 'is denied on a locked resource' do
        @resource.update!(is_editable: false)

        generate_fields

        assert_response :forbidden
        assert_equal 0, @resource.resource_fields.count
      end

      test 'is denied when the permission set is locked' do
        @set.update!(is_editable: false)

        generate_fields

        assert_response :forbidden
        assert_equal 0, @resource.resource_fields.count
      end

      private

      def generate_fields
        post "/permission_forge/api/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/generate_fields",
             params: { grant_all: 'true' }
      end
    end
  end
end
