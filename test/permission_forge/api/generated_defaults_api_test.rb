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

      # Field test round 8 (A#54, D#24): name "" or "   " answered 201, and
      # PATCH name "" 200, for a rule only — sets and groups refused it.
      test 'a blank name is refused on create and on update for a Permission Set, a group and a rule' do
        rule = create_permission_set_rule(permission_set: @ps, resource: @resource)
        group = PermissionSetGroup.create!(name: 'Ops', is_active: true)
        ['', '   '].each do |blank|
          assert_no_difference -> { PermissionSetRule.count } do
            post rules_path, params: { permission_set_rule: { name: blank, field_name: 'name', field_value: 'x', operator: 'equal' } }, as: :json
          end
          assert_response :unprocessable_entity
          assert_equal [I18n.t('permission_forge.validations.name_blank')], messages.fetch('name'), blank.inspect

          post '/permission_forge/api/permission_sets', params: { permission_set: { name: blank } }, as: :json
          assert_response :unprocessable_entity
          post '/permission_forge/api/permission_set_groups', params: { permission_set_group: { name: blank } }, as: :json
          assert_response :unprocessable_entity
        end

        patch "#{rules_path}/#{rule.uuid}", params: { permission_set_rule: { name: '' } }, as: :json
        assert_response :unprocessable_entity
        assert_equal rule.name, rule.reload.name
        patch "/permission_forge/api/permission_sets/#{@ps.uuid}", params: { permission_set: { name: ' ' } }, as: :json
        assert_response :unprocessable_entity
        patch "/permission_forge/api/permission_set_groups/#{group.uuid}", params: { permission_set_group: { name: '' } }, as: :json
        assert_response :unprocessable_entity
      end

      # Review of round 7 (P2-5): {"name":["can't be blank","can't be blank"]}
      # — the presence rule and the NOT NULL column both answered.
      test 'POST create without a name or a value names each once' do
        post '/permission_forge/api/permission_sets', params: { permission_set: { description: 'No name' } }
        assert_equal 1, messages.fetch('name').size, messages.inspect

        post '/permission_forge/api/permission_set_groups', params: { permission_set_group: { description: 'No name' } }
        assert_equal 1, messages.fetch('name').size, messages.inspect

        post rules_path, params: { permission_set_rule: { field_name: 'name', operator: 'equal' } }
        assert_equal 1, messages.fetch('name').size, messages.inspect
        assert_equal 1, messages.fetch('field_value').size, messages.inspect
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
