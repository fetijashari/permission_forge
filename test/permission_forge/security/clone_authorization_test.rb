# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class CloneAuthorizationTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set(name: 'Original')
        create_resource(permission_set: @ps, name: 'Customer')
        @group = create_permission_set_group(name: 'Original Group')
      end

      teardown do
        PermissionForge.configuration.api_action_authorization = nil
      end

      # --- Permission Sets ---

      test 'clone succeeds when api_action_authorization is nil' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone", params: { name: 'Cloned' }
        assert_response :created
      end

      test 'clone succeeds when authorizer returns true' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _a, _r) { true }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone", params: { name: 'Cloned' }
        assert_response :created
      end

      test 'clone returns 403 when authorizer returns false' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _a, _r) { false }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone", params: { name: 'Cloned' }
        assert_response :forbidden
        json = JSON.parse(response.body)
        assert json['error']['messages'].present?
      end

      test 'clone authorizer receives correct action and record' do
        received = {}
        PermissionForge.configuration.api_action_authorization = lambda { |_c, action, record|
          received[:action] = action
          received[:record] = record
          true
        }

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/clone"
        assert_equal :clone, received[:action]
        assert_equal @ps.id, received[:record].id
      end

      # --- Permission Set Groups ---

      test 'group clone succeeds when api_action_authorization is nil' do
        post "/permission_forge/api/permission_set_groups/#{@group.uuid}/clone", params: { name: 'Cloned' }
        assert_response :created
      end

      test 'group clone returns 403 when authorizer returns false' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _a, _r) { false }

        post "/permission_forge/api/permission_set_groups/#{@group.uuid}/clone", params: { name: 'Cloned' }
        assert_response :forbidden
      end
    end
  end
end
