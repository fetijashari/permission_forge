# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # Crafted input to the admin screens and the API answers 4xx (or is
    # ignored), never a 500: a String or an Array where a Hash is expected,
    # a Hash where an id is, out-of-range numbers and dates, blank names,
    # control characters in return_to. (The dummy app raises instead of
    # rendering error pages: a 400 shows up as BadRequest/ParameterMissing,
    # which Rails answers with 400.)
    class BadInputHtmlTest < ActionDispatch::IntegrationTest
      ROOT = '/permission_forge'

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @action = create_resource_action(resource: @resource)
        @group = create_permission_set_group(name: 'Team')
        @user = create_user(name: 'Ana')
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @set_path = "#{ROOT}/permission_sets/#{@set.id}"
        @resource_path = "#{@set_path}/resources/Customer"
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      test 'restore with an impossible end date is a 400 and restores nothing' do
        @assignment.destroy!

        assert_raises(ActionController::BadRequest) do
          post "#{ROOT}/assignments/restore", params: { permission_set_id: @set.id, user_id: @user.id, expires_at: '25:99' }
        end
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'restore with an unreadable end date is a 400, not a permanent assignment' do
        @assignment.destroy!

        ['soon', 'tuesday', 'next tuesday-ish', '2026-13-45', '2030-02-30', 'banana'].each do |value|
          assert_raises(ActionController::BadRequest, value) do
            post "#{ROOT}/assignments/restore", params: { permission_set_id: @set.id, user_id: @user.id, expires_at: value }
          end
        end
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)
      end

      test 'undo with a Hash for ids removes nothing' do
        post "#{ROOT}/assignments/undo", params: { ids: { 'a' => @assignment.id } }

        assert_response :redirect
        assert PermissionForge::PermissionSetUser.exists?(@assignment.id)
      end

      test 'the assign form ignores set ids that are not ids' do
        get "#{ROOT}/assignments/new", params: { user_id: @user.id, set_ids: ['1', { 'b' => 2 }] }
        assert_response :ok

        post "#{ROOT}/assignments", params: { user_id: @user.id, set_ids: { 'a' => '1' } }
        assert_response :unprocessable_entity
      end

      test 'the people list takes any page and a long number as search' do
        get "#{ROOT}/people", params: { page: '9' * 40 }
        assert_response :ok
        get "#{ROOT}/people", params: { page: { 'a' => '1' } }
        assert_response :ok
        get "#{ROOT}/people", params: { q: '9' * 40 }
        assert_response :ok
        post "#{@set_path}/bulk_assignment/preview", params: { q: '9' * 40 }
        assert_response :ok
      end

      test 'a form section that is not a Hash is a 400' do
        assert_raises(ActionController::ParameterMissing) { patch "#{@resource_path}/fields/email", params: { field: 'x' } }
        assert_raises(ActionController::ParameterMissing) { patch "#{ROOT}/groups/#{@group.id}", params: { group: ['x'] } }
        assert_raises(ActionController::ParameterMissing) do
          patch "#{@resource_path}/actions/#{@action.id}", params: { resource_action: 'x' }
        end
      end

      test 'a rule form that is not a Hash re-renders the builder' do
        patch "#{@resource_path}/rules/#{@rule.id}", params: { rule: 'x' }

        assert_response :unprocessable_entity
        assert_equal 'Test Rule', @rule.reload.name
      end

      test 'batched edits that are not a Hash change nothing' do
        %w[x].push(['1', { 'b' => 2 }]).each do |value|
          patch "#{@set_path}/apply", params: { pf: value }
          assert_response :redirect
          post "#{@set_path}/review", params: { pf: value }
          assert_response :redirect
          patch "#{@resource_path}/apply", params: { pf: value }
          assert_response :redirect
        end
        patch "#{@set_path}/apply", params: { pf: { set: 'x', fields: 'y', resources: ['z'] } }
        assert_response :redirect
        assert_equal 'Sales', @set.reload.name
      end

      test 'a blank Permission Set name is refused with an alert, not a 500' do
        patch "#{@set_path}/apply", params: { pf: { set: { name: '' } } }

        assert_redirected_to @set_path
        assert_match(/Name/, flash[:alert])
        assert_equal 'Sales', @set.reload.name
      end

      test 'a group id that is not a group is refused or ignored' do
        patch "#{@set_path}/apply", params: { pf: { set: { permission_set_group_id: { 'x' => 1 } } } }
        assert_response :redirect
        patch "#{@set_path}/apply", params: { pf: { set: { permission_set_group_id: 'abc' } } }
        assert_response :redirect
        patch "#{@set_path}/apply", params: { pf: { set: { permission_set_group_id: '999999' } } }
        assert_response :redirect

        assert_nil @set.reload.permission_set_group_id
      end

      test 'a NUL inside a people search or a pasted identifier is ignored, not a 500' do
        get "#{ROOT}/people", params: { q: "a\u0000na" }
        assert_response :ok
        assert_includes response.body, 'Ana'
        get "#{ROOT}/assignments/new", params: { q: "a\u0000b" }
        assert_response :ok
        get "#{@set_path}/bulk_assignment/new", params: { q: "a\u0000b" }
        assert_response :ok
        post "#{@set_path}/bulk_assignment/preview", params: { identifiers: "a\u0000b\nfirst last\u0000" }
        assert_response :ok
      end

      test 'a NUL in a new set or group name or a set search is dropped (Rails 7.1 inlines the value in SQL)' do
        post "#{ROOT}/permission_sets", params: { name: "Ne\u0000w", type: 'granting' }
        assert_response :redirect
        assert PermissionForge::PermissionSet.exists?(name: 'New')

        post "#{ROOT}/groups", params: { name: "Gr\u0000oup" }
        assert PermissionForge::PermissionSetGroup.exists?(name: 'Group')

        get "#{ROOT}/assignments/new", params: { user_id: @user.id, set_q: "Sa\u0000les" }
        assert_response :ok
      end

      test 'NUL bytes inside the admin forms are dropped before anything is stored' do
        patch "#{@set_path}/apply", params: { pf: { set: { description: "de\u0000sc" } } }
        assert_equal 'desc', @set.reload.description
        patch "#{ROOT}/groups/#{@group.id}", params: { group: { name: "Te\u0000am 2" } }
        assert_equal 'Team 2', @group.reload.name
      end

      test 'a tab that is not a tab name is dropped from the redirect' do
        [{ 'a' => '1' }, ['x', { 'b' => '2' }]].each do |tab|
          post "#{ROOT}/people/#{@user.id}/refresh_cache", params: { tab: tab }
          assert_redirected_to "#{ROOT}/people/#{@user.id}"
          patch "#{@resource_path}/apply", params: { tab: tab }
          assert_response :redirect
          post "#{@resource_path}/review", params: { tab: tab }
          assert_response :redirect
          post "#{@resource_path}/sync", params: { tab: tab }
          assert_response :redirect
        end
        post "#{ROOT}/people/#{@user.id}/refresh_cache", params: { tab: 'effective' }
        assert_redirected_to "#{ROOT}/people/#{@user.id}?tab=effective"
      end

      test 'hours that are not numbers re-render the conditions tab' do
        [{ 'a' => '1' }, ['8']].each do |hour|
          patch "#{@set_path}/conditions", params: { allowed_ips: 'nonsense', hours_enabled: '1',
                                                     allowed_hours_start: hour, allowed_hours_end: hour }
          assert_response :unprocessable_entity
          patch "#{@set_path}/conditions", params: { hours_enabled: '1', allowed_hours_start: hour, allowed_hours_end: '18' }
          assert_includes [302, 422], response.status
        end
        assert_nil @set.reload.allowed_hours_start
      end

      # R2 review, P0-2: read only while tab=audit, so the all-at-once fuzz
      # never reached them.
      test 'the audit tab reads a Hash or a list in days, who, type or views as no filter' do
        [{ 'a' => '1' }, ['7', { 'b' => '2' }], "a\u0000b", '-30', '9' * 40].each do |value|
          %w[days who type views].each do |param|
            get @set_path, params: { tab: 'audit', param => value }
            assert_response :ok, "#{param}=#{value.inspect}"
            get "#{@set_path}.csv", params: { tab: 'audit', param => value }
            assert_response :ok, "csv #{param}=#{value.inspect}"
          end
        end
      end

      test 'the audit tab still filters by a day count it offers' do
        PermissionForge.configuration.audit_trail_enabled = true
        get @set_path, params: { tab: 'audit', days: '30' }

        assert_response :ok
        assert_select 'option[selected][value="30"]'
      end

      # R2 review, P0-3: path.first(-1) raised ArgumentError (a 500).
      test 'the rule builder reads a negative or huge remove_step as no removal' do
        ['-1', '9' * 40, '1abc', { 'a' => '1' }, ['1']].each do |value|
          post "#{@resource_path}/rules/refresh", params: { rule: { path: %w[orders], remove_step: value, field_name: 'name' } }
          assert_response :ok, "remove_step=#{value.inspect}"
        end
      end

      test 'return_to with a backslash or a control character falls back to the default' do
        ['/\\evil.com', "/\tevil.com", "/\nx", '/\\/evil.com'].each do |target|
          patch "#{ROOT}/assignments/#{@assignment.id}", params: { expiry: 'extend30', return_to: target }
          assert_redirected_to "#{ROOT}/people/#{@user.id}"
        end
      end
    end

    class BadInputApiTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      ROOT = '/permission_forge/api'

      setup do
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @user = create_user
      end

      test 'a record body that is not a Hash is a 422' do
        post "#{ROOT}/permission_sets", params: { permission_set: 'x' }
        assert_response :unprocessable_entity
        patch "#{ROOT}/permission_sets/#{@set.uuid}", params: { permission_set: ['x'] }
        assert_response :unprocessable_entity
        post "#{ROOT}/permission_sets/#{@set.uuid}/resources", params: { resource: 'x' }
        assert_response :unprocessable_entity
        post "#{ROOT}/permission_set_groups", params: { permission_set_group: 'x' }
        assert_response :unprocessable_entity
      end

      test 'blank names are a 422 for sets, groups, fields and actions' do
        post "#{ROOT}/permission_sets", params: { permission_set: { name: '' } }
        assert_response :unprocessable_entity
        assert response.parsed_body.dig('error', 'messages', 'name').present?

        post "#{ROOT}/permission_set_groups", params: { permission_set_group: { name: ' ' } }
        assert_response :unprocessable_entity

        post "#{ROOT}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/fields", params: { resource_field: { name: '' } }
        assert_response :unprocessable_entity

        assert_raises(ActiveRecord::RecordInvalid) { create_resource_action(resource: @resource, name: '') }
      end

      test 'a blank name message is translated' do
        I18n.with_locale(:sq) do
          set = PermissionForge::PermissionSet.new(name: '')
          set.valid?
          assert_includes set.errors[:name], I18n.t('permission_forge.validations.name_blank')
        end
      end

      test 'a group that does not exist is a 422' do
        post "#{ROOT}/permission_sets", params: { permission_set: { name: 'New', permission_set_group_id: 999_999 } }
        assert_response :unprocessable_entity
      end

      test 'a null-check rule needs no field_value (legitimate input, never a 500)' do
        path = "#{ROOT}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules"
        %w[is_null is_not_null].each do |operator|
          post path, params: { permission_set_rule: { name: operator, field_name: 'name', operator: operator } }
          assert_response :created
          assert_equal '', response.parsed_body.dig('data', 'field_value').to_s
        end

        rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        patch "#{path}/#{rule.uuid}", params: { permission_set_rule: { field_value: nil, operator: 'is_null' } }
        assert_response :ok
        assert_equal ['is_null', ''], rule.reload.values_at(:operator, :field_value)

        post path, params: { permission_set_rule: { name: 'eq', field_name: 'name', operator: 'equal' } }
        assert_response :unprocessable_entity
      end

      test 'NUL bytes inside attribute hashes are dropped before anything is stored' do
        post "#{ROOT}/permission_sets", params: { permission_set: { name: "Ne\u0000w", description: "d\u0000" } }
        assert_response :created
        assert_equal %w[New d], PermissionForge::PermissionSet.find_by!(name: 'New').values_at(:name, :description)

        path = "#{ROOT}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}/rules"
        post path, params: { permission_set_rule: { name: 'r', field_name: 'name', operator: 'equal',
                                                    field_value: "x\u0000y", failure_message: "no\u0000" } }
        assert_response :created
        assert_equal %w[xy no], PermissionForge::PermissionSetRule.find_by!(name: 'r').values_at(:field_value, :failure_message)
      end

      test 'page and per_page that are not numbers are ignored' do
        get "#{ROOT}/permission_sets", params: { page: { 'a' => '1' }, per_page: ['1', { 'b' => 2 }] }
        assert_response :ok
        get "#{ROOT}/audit_events", params: { page: ['1'], per_page: { 'a' => '1' } }
        assert_response :ok
      end

      test 'an unreadable expires_at is a 422, not a permanent assignment' do
        ['25:99', 'soon', 'tuesday', 'next tuesday-ish', '2026-13-45', 'banana'].each do |value|
          post "#{ROOT}/permission_sets/#{@set.uuid}/users", params: { user_id: @user.id, expires_at: value }
          assert_response :unprocessable_entity
          post "#{ROOT}/permission_sets/#{@set.uuid}/users/bulk", params: { user_ids: [@user.id], bulk_action: 'assign', expires_at: value }
          assert_response :unprocessable_entity
        end
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @user.id)

        post "#{ROOT}/permission_sets/#{@set.uuid}/users", params: { user_id: @user.id, expires_at: 2.days.from_now.iso8601 }
        assert_response :created
      end
    end
  end
end
