# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # JSON null, or a blank form value, for a NOT NULL column is a 422 keyed
    # by the attribute in the API and the form again in the admin — never the
    # database's NotNullViolation (a 500). R2 review, P0-1.
    class NotNullInputTest < ActionDispatch::IntegrationTest
      ROOT = '/permission_forge'
      API = "#{ROOT}/api".freeze

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @action = create_resource_action(resource: @resource)
        @group = create_permission_set_group(name: 'Team')
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      # [collection path, member path, body key, a valid create body, NOT NULL attributes to null]
      def endpoints
        resource = "#{API}/permission_sets/#{@set.uuid}/resources"
        [
          ["#{resource}/#{@resource.uuid}/fields", "#{resource}/#{@resource.uuid}/fields/#{@field.uuid}", :resource_field,
           { name: 'phone', label: 'Phone', read_access: true },
           %w[label mask_strategy is_active is_editable read_access edit_access mask_access]],
          [resource, "#{resource}/#{@resource.uuid}", :resource, { name: 'Supplier', read_access: true },
           %w[is_active is_editable read_access create_access edit_access delete_access view_all modify_all]],
          ["#{API}/permission_sets", "#{API}/permission_sets/#{@set.uuid}", :permission_set, { name: 'Other' },
           %w[is_active is_editable is_muting]],
          ["#{resource}/#{@resource.uuid}/rules", "#{resource}/#{@resource.uuid}/rules/#{@rule.uuid}", :permission_set_rule,
           { name: 'r', field_name: 'name', field_value: 'x', operator: 'equal' },
           %w[name include_nulls is_active is_editable operator]],
          ["#{resource}/#{@resource.uuid}/actions", "#{resource}/#{@resource.uuid}/actions/#{@action.uuid}", :resource_action,
           { name: 'export', label: 'Export' }, %w[is_permitted is_active]],
          ["#{API}/permission_set_groups", "#{API}/permission_set_groups/#{@group.uuid}", :permission_set_group,
           { name: 'Other team' }, %w[is_active is_editable]]
        ]
      end

      test 'API: JSON null or a blank form value on a NOT NULL column is a 422 keyed by the attribute, on create and update' do
        failures = endpoints.flat_map do |collection, member, key, body, columns|
          columns.flat_map do |column|
            [[:post, collection, body.stringify_keys], [:patch, member, {}]].flat_map do |verb, path, rest|
              null_shapes(column).filter_map do |value, as|
                code, json = api_answer(verb, path, { key => rest.merge(column => value) }, as)
                next if code == 422 && json.dig('error', 'messages', column).is_a?(Array)
                # A blank label is no label, stored as the row's name, on create
                # and on update (Concerns::NormalizesLabel; blank_label_api_test.rb).
                next if column == 'label' && [200, 201].include?(code) && json.dig('data', 'label') == (rest['name'] || @field.name)

                "#{verb.upcase} #{key}.#{column}=#{value.inspect} (#{as || :form}): #{code} #{json.to_s[0, 120]}"
              end
            end
          end
        end

        assert_empty failures
      end

      # A blank flag is no boolean (ParamShapes.boolean): the flag's own
      # message, as for any word the admin cannot read.
      test 'admin: a blank Active flag on the group form goes back to the group with the message' do
        patch "#{ROOT}/groups/#{@group.id}", params: { group: { is_active: '' } },
                                             headers: { 'HTTP_REFERER' => "http://www.example.com#{ROOT}/groups/#{@group.id}" }

        assert_redirected_to "#{ROOT}/groups/#{@group.id}"
        assert_includes flash[:alert].to_s, I18n.t('permission_forge.api.errors.boolean_invalid')
        assert @group.reload.is_active
      end

      # A NOT NULL violation that no validation foresaw (a host column, a
      # trigger) is the 422 envelope in the API and a flash in the admin.
      test 'API: an unforeseen NotNullViolation is a 422 envelope' do
        raising_not_null(PermissionForge::PermissionSetGroup) do
          post "#{API}/permission_set_groups", params: { permission_set_group: { name: 'X' } }, as: :json
        end

        assert_response :unprocessable_entity
        assert_equal [I18n.t('permission_forge.api.errors.not_null')], JSON.parse(response.body).dig('error', 'messages', 'base')
      end

      test 'admin: an unforeseen NotNullViolation goes back with a flash' do
        referer = "http://www.example.com#{ROOT}/groups/#{@group.id}"
        raising_not_null(PermissionForge::PermissionSetGroup) do
          patch "#{ROOT}/groups/#{@group.id}", params: { group: { name: 'Renamed' } }, headers: { 'HTTP_REFERER' => referer }
        end

        assert_response :see_other
        assert_redirected_to referer
        assert_equal I18n.t('permission_forge.flash.not_null'), flash[:alert]
      end

      private

      # JSON null for every column; a blank form value, which a boolean
      # column casts to nil (a string column keeps '').
      def null_shapes(column)
        boolean = column.start_with?('is_') || column.end_with?('_access', '_all', '_nulls')
        boolean ? [[nil, :json], ['', nil]] : [[nil, :json]]
      end

      def api_answer(verb, path, params, as)
        send(verb, path, params: params, as: as)
        [response.status, (JSON.parse(response.body) rescue {})] # rubocop:disable Style/RescueModifier
      rescue StandardError => e
        ["#{e.class}: #{e.message[0, 100]}", {}]
      end

      def raising_not_null(klass)
        klass.class_eval { before_save :pf_test_raise_not_null }
        klass.define_method(:pf_test_raise_not_null) { raise ActiveRecord::NotNullViolation, 'NOT NULL constraint failed: x.y' }
        yield
      ensure
        klass.skip_callback(:save, :before, :pf_test_raise_not_null)
        klass.remove_method(:pf_test_raise_not_null)
      end
    end
  end
end
