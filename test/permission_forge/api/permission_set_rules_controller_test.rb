# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetRulesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer')
      end

      test 'GET index returns rules for a resource' do
        create_permission_set_rule(permission_set: @ps, resource: @resource)

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 1, json['data'].size
      end

      test 'POST create creates a rule' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules", params: {
          permission_set_rule: {
            name: 'Own records only',
            field_name: 'user_id',
            field_value: 'current_user',
            operator: 'equal',
            include_nulls: false
          }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'Own records only', json.dig('data', 'name')
        assert_equal 'equal', json.dig('data', 'operator')
        assert_equal @ps.id, json.dig('data', 'permission_set_id')
      end

      test 'PATCH update modifies a rule' do
        rule = create_permission_set_rule(permission_set: @ps, resource: @resource)

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules/#{rule.uuid}", params: {
          permission_set_rule: { operator: 'not_equal' }
        }

        assert_response :ok
        assert_equal 'not_equal', rule.reload.operator
      end

      test 'DELETE destroy removes a rule' do
        rule = create_permission_set_rule(permission_set: @ps, resource: @resource)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules/#{rule.uuid}"

        assert_response :no_content
      end
    end
  end
end
