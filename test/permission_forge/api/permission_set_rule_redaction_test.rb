# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetRuleRedactionTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer')
        @rule = create_permission_set_rule(
          permission_set: @ps,
          resource: @resource,
          field_name: 'name',
          field_value: 'sensitive_account_123'
        )
      end

      test 'field_value is visible by default' do
        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'sensitive_account_123', json['data'].first['field_value']
      end

      test 'field_value is redacted when api_redact_rule_field_values is true' do
        PermissionForge.configuration.api_redact_rule_field_values = true

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal '[REDACTED]', json['data'].first['field_value']
      ensure
        PermissionForge.configuration.api_redact_rule_field_values = false
      end

      test 'field_value is redacted in single record response' do
        PermissionForge.configuration.api_redact_rule_field_values = true

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}/rules/#{@rule.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal '[REDACTED]', json['data']['field_value']
      ensure
        PermissionForge.configuration.api_redact_rule_field_values = false
      end
    end
  end
end
