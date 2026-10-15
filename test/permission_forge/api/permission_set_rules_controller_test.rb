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
            field_name: 'supplier_id',
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

      # A field name that is no column used to be saved (201) and then turned
      # every permission_scoped / find_by of the set's holders into a 500.
      test 'POST create answers 422 on field_name for a column the model does not have' do
        assert_no_difference -> { PermissionForge::PermissionSetRule.count } do
          post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules", params: {
            permission_set_rule: { name: 'Owner', field_name: 'onwer_id', field_value: 'current_user', operator: 'equal' }
          }
        end

        assert_response :unprocessable_entity
        assert_equal({ 'field_name' => ['is not a column of Customer'] }, JSON.parse(response.body).dig('error', 'messages'))
      end

      test 'PATCH answers 422 for a rename to a missing column, and leaves an old row editable otherwise' do
        rule = create_permission_set_rule(permission_set: @ps, resource: @resource)
        path = "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules/#{rule.uuid}"

        patch path, params: { permission_set_rule: { field_name: 'supplierid' } }

        assert_response :unprocessable_entity
        assert_equal ['is not a column of Customer'], JSON.parse(response.body).dig('error', 'messages', 'field_name')

        rule.update_columns(field_name: 'onwer_id')
        patch path, params: { permission_set_rule: { field_value: '5', is_active: false } }

        assert_response :ok
        assert_equal '5', rule.reload.field_value
      end

      test 'DELETE destroy removes a rule' do
        rule = create_permission_set_rule(permission_set: @ps, resource: @resource)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules/#{rule.uuid}"

        assert_response :no_content
      end
    end
  end
end
