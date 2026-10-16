# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  module Api
    # A value of the wrong shape for its attribute is a 422 keyed by that
    # attribute: never dropped, never cast into something else, never a 500
    # (field test round 7, d-api #54 and #59). Through 0.15.0-rc strong
    # parameters dropped a list or an object sent for a scalar (a PATCH
    # `{"is_active": [false]}` answered 200 with the set still active), and
    # ActiveModel cast what remained: `"nope"` was true, a JSON `true` for a
    # name stored "t". One shape table, Api::InputShapes, reads every
    # attribute section of the API (`pf_record_attributes`).
    class InputShapesTest < ActionDispatch::IntegrationTest
      API = '/permission_forge/api'
      API_CONTROLLERS = 'app/controllers/permission_forge/api/**/*.rb'
      HELPER = /\bpf_record_attributes\(\s*:(\w+)\s*,\s*([\w:]+)\s*,([^)]*)\)/m
      PERMIT_GUARD = { globs: [API_CONTROLLERS, 'app/controllers/concerns/permission_forge/api/**/*.rb'], needle: /\.permit\b/ }.freeze
      PERMIT_ALLOWLIST = [
        ['app/controllers/permission_forge/api/base_controller.rb', /\.except\(.*\)\.permit\b/,
         "pf_record_attributes: the keys an endpoint does not take go through strong parameters' own handling (logged, or " \
         'raised under action_on_unpermitted_parameters = :raise)']
      ].freeze

      setup do
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'name', field_value: 'x')
        @action = create_resource_action(resource: @resource)
        @group = create_permission_set_group(name: 'Team')
        @user = create_user(name: 'Ana')
      end

      # ---- booleans ---------------------------------------------------------

      test 'a list, an object, an unknown word, a fraction or "" for a boolean is a 422 keyed by it and changes nothing' do
        [[false], { 'value' => false }, 'nope', 'yes', 1.5, 2, ''].each do |value|
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { is_active: value } }, as: :json
          assert_keyed_refusal('is_active', I18n.t('permission_forge.api.errors.boolean_invalid'), value)
        end
        assert @set.reload.is_active, 'nothing was deactivated, and nothing read "nope" as true'
      end

      test 'a boolean is true, false, 1, 0 or a word true/false/t/f/on/off/1/0 in any case' do
        { false => false, true => true, 0 => false, 1 => true, 'FALSE' => false, 'True' => true, 'off' => false,
          'On' => true, 'f' => false, 'T' => true, '0' => false, '1' => true }.each do |value, expected|
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { is_active: value } }, as: :json
          assert_response :ok, "#{value.inspect}: #{response.body}"
          assert_equal expected, @set.reload.is_active, value.inspect
        end
      end

      test 'a form-encoded boolean takes the same words' do
        patch "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}", params: { resource: { edit_access: 'on' } }
        assert_response :ok, response.body
        assert @resource.reload.edit_access

        patch "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}", params: { resource: { read_access: 'nope' } }
        assert_keyed_refusal('read_access', I18n.t('permission_forge.api.errors.boolean_invalid'), 'nope')
        assert @resource.reload.read_access
      end

      # ---- text -------------------------------------------------------------

      test 'true, a number, a list or an object for a text attribute is a 422 keyed by it; nothing is renamed' do
        [true, 1.5, 7, ['Renamed'], { 'a' => 'b' }].each do |value|
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { name: value } }, as: :json
          assert_keyed_refusal('name', I18n.t('permission_forge.api.errors.text_shape'), value)
          patch "#{API}/permission_set_groups/#{@group.uuid}", params: { permission_set_group: { description: value } }, as: :json
          assert_keyed_refusal('description', I18n.t('permission_forge.api.errors.text_shape'), value)
        end
        assert_equal 'Sales', @set.reload.name
        assert_equal 'A test group', @group.reload.description
      end

      test 'every wrong attribute of one request is named' do
        patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { name: true, is_muting: 'nope', description: 'ok' } }, as: :json

        assert_response :unprocessable_entity
        assert_equal %w[is_muting name], response.parsed_body.dig('error', 'messages').keys.sort
      end

      test 'null clears a nullable column; a NOT NULL one keeps its own validation' do
        patch "#{API}/permission_set_groups/#{@group.uuid}", params: { permission_set_group: { description: nil } }, as: :json
        assert_response :ok, response.body
        assert_nil @group.reload.description

        patch "#{API}/permission_set_groups/#{@group.uuid}", params: { permission_set_group: { is_active: nil } }, as: :json
        assert_response :unprocessable_entity
        assert response.parsed_body.dig('error', 'messages', 'is_active').is_a?(Array)
      end

      # ---- the group reference ----------------------------------------------

      test 'permission_set_group_id takes the group uuid or id; null and "" clear it; a list or an object is a 422 keyed by it' do
        [@group.uuid, @group.id].each do |value|
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { permission_set_group_id: value } }, as: :json
          assert_response :ok, response.body
          assert_equal @group.id, @set.reload.permission_set_group_id
        end
        [nil, ''].each do |value|
          @set.update!(permission_set_group: @group)
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { permission_set_group_id: value } }, as: :json
          assert_response :ok, response.body
          assert_nil @set.reload.permission_set_group_id
        end
        @set.update!(permission_set_group: @group)
        [[@group.uuid], { 'id' => @group.id }, true].each do |value|
          patch "#{API}/permission_sets/#{@set.uuid}", params: { permission_set: { permission_set_group_id: value } }, as: :json
          assert_keyed_refusal('permission_set_group_id', I18n.t('permission_forge.validations.permission_set.group_missing'), value)
        end
        assert_equal @group.id, @set.reload.permission_set_group_id
      end

      # ---- a rule's value -----------------------------------------------------

      test 'a JSON number or boolean for field_value is stored as its text' do
        { 5 => '5', 1.5 => '1.5', true => 'true', false => 'false' }.each do |value, text|
          patch rule_path, params: { permission_set_rule: { field_value: value } }, as: :json
          assert_response :ok, "#{value.inspect}: #{response.body}"
          assert_equal text, @rule.reload.field_value
        end
      end

      test 'a list for field_value under in, not_in or between is joined with commas' do
        post rules_path, params: { permission_set_rule: { name: 'Statuses', field_name: 'name', operator: 'in',
                                                          field_value: %w[active lead] } }, as: :json
        assert_response :created, response.body
        assert_equal 'active,lead', PermissionForge::PermissionSetRule.find_by(name: 'Statuses').field_value

        @rule.update!(operator: 'between', field_value: 'a,b')
        patch rule_path, params: { permission_set_rule: { field_value: %w[c d] } }, as: :json
        assert_response :ok, response.body
        assert_equal 'c,d', @rule.reload.field_value, 'the stored operator decides on an update'

        patch rule_path, params: { permission_set_rule: { operator: 'not_in', field_value: [1, 2] } }, as: :json
        assert_response :ok, response.body
        assert_equal '1,2', @rule.reload.field_value
      end

      test 'a list for field_value under another operator, with an object or a comma in it, or an object, is a 422 keyed by field_value' do
        message = I18n.t('permission_forge.api.errors.field_value_shape')
        [%w[a b], { 'a' => 'b' }].each do |value|
          patch rule_path, params: { permission_set_rule: { field_value: value } }, as: :json
          assert_keyed_refusal('field_value', message, value)
        end
        [['a', { 'b' => 'c' }], ['a,b', 'c'], [], [%w[a]]].each do |value|
          patch rule_path, params: { permission_set_rule: { operator: 'in', field_value: value } }, as: :json
          assert_keyed_refusal('field_value', message, value)
        end
        assert_equal 'x', @rule.reload.field_value
        assert_equal 'equal', @rule.operator
      end

      # ---- the parameters outside a section -------------------------------------

      test 'a copy name that is not text is a 422 keyed by name, and nothing is copied' do
        [true, 7, ['Copy'], { 'a' => 'b' }].each do |value|
          assert_no_difference(-> { PermissionForge::PermissionSet.count }) do
            post "#{API}/permission_sets/#{@set.uuid}/clone", params: { name: value }, as: :json
            assert_keyed_refusal('name', I18n.t('permission_forge.api.errors.text_shape'), value)
            post "#{API}/permission_set_groups/#{@group.uuid}/clone", params: { name: value }, as: :json
            assert_keyed_refusal('name', I18n.t('permission_forge.api.errors.text_shape'), value)
          end
        end
        post "#{API}/permission_sets/#{@set.uuid}/clone", params: { name: nil }, as: :json
        assert_response :created, 'null is the default copy name'
      end

      test 'a bulk user_ids with an element that is no id is a 422 keyed by user_ids, and nobody is assigned' do
        [[@user.id, { 'id' => 1 }], [[@user.id]], [@user.id, 1.5], [@user.id, true]].each do |value|
          assert_no_difference(-> { PermissionForge::PermissionSetUser.count }) do
            post "#{API}/permission_sets/#{@set.uuid}/users/bulk", params: { bulk_action: 'assign', user_ids: value }, as: :json
          end
          assert_keyed_refusal('user_ids', I18n.t('permission_forge.api.errors.user_ids_not_list'), value)
        end
      end

      test 'a bulk_action that is not one of the words is a 422 keyed by bulk_action' do
        [['assign'], { 'a' => 'assign' }, true, 1].each do |value|
          post "#{API}/permission_sets/#{@set.uuid}/users/bulk", params: { bulk_action: value, user_ids: [@user.id] }, as: :json
          assert_keyed_refusal('bulk_action', I18n.t('permission_forge.api.errors.bulk_action_invalid'), value)
        end
      end

      # ---- the guards -----------------------------------------------------------

      # Strong parameters' permit drops a list or an object sent for a scalar
      # with a log line: every API attribute section is read through
      # pf_record_attributes, the one place that also reads the keys it does
      # not take (logged as strong parameters log them).
      test 'no .permit in the API controllers outside pf_record_attributes' do
        hits = StaticGuard.scan(**PERMIT_GUARD, allowlist: PERMIT_ALLOWLIST)

        assert_empty hits.map(&:to_s), 'read an attribute section with pf_record_attributes (Api::InputShapes)'
        StaticGuard.assert_allowlist_current(self, **PERMIT_GUARD, allowlist: PERMIT_ALLOWLIST)
      end

      test 'every attribute an API section takes has a shape' do
        sections = StaticGuard.files([API_CONTROLLERS]).flat_map { |file| File.read(file).scan(HELPER) }
        assert_operator sections.size, :>=, 6, 'the scan finds the API sections'

        unshaped = sections.flat_map do |_section, model, keys|
          klass = model.constantize
          keys.scan(/:(\w+)/).flatten.filter_map { |key| "#{model}##{key}" if InputShapes.shape_of(klass, key) == :as_is }
        end
        assert_empty unshaped, 'give these attributes a shape (InputShapes::DECLARED or a column type in BY_TYPE)'
      end

      private

      def rule_path = "#{rules_path}/#{@rule.uuid}"
      def rules_path = "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules"

      def assert_keyed_refusal(attribute, message, value)
        assert_response :unprocessable_entity, "#{attribute} = #{value.inspect}: #{response.body}"
        assert_equal [message], response.parsed_body.dig('error', 'messages', attribute), "#{attribute} = #{value.inspect}"
      end
    end
  end
end
