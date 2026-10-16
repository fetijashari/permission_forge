# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'

module PermissionForge
  module Api
    # Field test round 7 through the JSON API:
    #
    # - D#47 / critique 24: a create without a name stored the install
    #   migration's English column default ("Untitled Permission Set",
    #   "Untitled Rule") and answered 201; the models declare no default now,
    #   so it is the 422 keyed by `name` any other missing value gets. A rule
    #   created without a blocked message stores none (it denies with the
    #   sentence of the locale), not the English default.
    # - E#73: a rule on an attribute declared with `encrypts` answers 422 on
    #   `field_name`.
    # - D#22: a LIKE operator on a column it cannot match answers 422 on
    #   `operator`, naming the column type (it blamed the value).
    class GeneratedDefaultsApiTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer')
      end

      def rules_path(resource = @resource) = "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/rules"

      def messages = JSON.parse(response.body).dig('error', 'messages')

      test 'POST create without a name answers 422 on name for a Permission Set, a group and a rule' do
        assert_no_difference -> { PermissionSet.count } do
          post '/permission_forge/api/permission_sets', params: { permission_set: { description: 'No name' } }
        end
        assert_response :unprocessable_entity
        assert messages.key?('name'), messages.inspect

        assert_no_difference -> { PermissionSetGroup.count } do
          post '/permission_forge/api/permission_set_groups', params: { permission_set_group: { description: 'No name' } }
        end
        assert_response :unprocessable_entity
        assert messages.key?('name'), messages.inspect

        assert_no_difference -> { PermissionSetRule.count } do
          post rules_path, params: { permission_set_rule: { field_name: 'name', field_value: 'x', operator: 'equal' } }
        end
        assert_response :unprocessable_entity
        assert messages.key?('name'), messages.inspect
      end

      test 'POST create of a rule without a blocked message stores none' do
        post rules_path, params: { permission_set_rule: { name: 'Named', field_name: 'name', field_value: 'x', operator: 'equal' } }

        assert_response :created
        assert_nil JSON.parse(response.body).dig('data', 'failure_message')
        assert_nil PermissionSetRule.find_by!(name: 'Named').failure_message
      end

      test 'POST create answers 422 on field_name for a rule on an encrypted attribute' do
        notes = create_resource(permission_set: @ps, name: 'PfEncryptedNote')

        post rules_path(notes), params: { permission_set_rule: { name: 'Body', field_name: 'body', field_value: 'x', operator: 'equal' } }

        assert_response :unprocessable_entity
        assert_equal [I18n.t('permission_forge.validations.permission_set_rule.encrypted_column', name: 'body', model: 'PfEncryptedNote')],
                     messages['field_name']
      end

      test 'POST create answers 422 on operator, naming the column type, for a LIKE operator on a column it cannot match' do
        records = create_resource(permission_set: @ps, name: 'PfRulePathRecord')

        post rules_path(records), params: { permission_set_rule: { name: 'Details', field_name: 'details', field_value: 'x',
                                                                   operator: 'contains' } }

        assert_response :unprocessable_entity
        type = PfRulePathRecord.columns_hash['details'].sql_type
        assert_equal({ 'operator' => [I18n.t('permission_forge.validations.permission_set_rule.pattern_on_non_text',
                                             model: 'PfRulePathRecord', name: 'details', type: type)] }, messages)
      end
    end
  end
end
