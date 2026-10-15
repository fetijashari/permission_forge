require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # The JSON admin API never reads or writes across tenants: lists are per
    # tenant, another tenant's identifiers are a 404 on every verb, and created
    # records are stamped with the caller's tenant.
    class TenantApiIsolationTest < ActionDispatch::IntegrationTest
      include TenancyTestHelper

      BASE = '/permission_forge/api'.freeze

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user

        within(@tenant_a) do
          @set_a = create_permission_set(name: 'Alpha set')
          @resource_a = create_resource(permission_set: @set_a, name: 'Customer')
        end
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'Bravo set')
          @resource_b = create_resource(permission_set: @set_b, name: 'Supplier')
          @field_b = create_resource_field(resource: @resource_b, name: 'name')
          @rule_b = create_permission_set_rule(permission_set: @set_b, resource: @resource_b, field_name: 'owner_id')
          @assignment_b = create_permission_set_user(user: @user, permission_set: @set_b)
          @group_b = create_permission_set_group(name: 'Bravo group')
        end

        # Every request below runs as tenant A.
        ActsAsTenant.test_tenant = @tenant_a
      end

      test 'index lists only the current tenant permission sets' do
        get "#{BASE}/permission_sets"

        assert_response :ok
        assert_equal([@set_a.uuid], json['data'].map { |row| row['uuid'] })
      end

      test 'another tenant permission set is not found for show, update, destroy and clone' do
        get "#{BASE}/permission_sets/#{@set_b.uuid}"
        assert_response :not_found

        patch "#{BASE}/permission_sets/#{@set_b.uuid}", params: { permission_set: { name: 'Hijacked' } }
        assert_response :not_found

        delete "#{BASE}/permission_sets/#{@set_b.uuid}"
        assert_response :not_found

        post "#{BASE}/permission_sets/#{@set_b.uuid}/clone"
        assert_response :not_found

        within(@tenant_b) { assert_equal 'Bravo set', PermissionForge::PermissionSet.find(@set_b.id).name }
      end

      test 'nested resources, fields and rules of another tenant are not found' do
        get "#{BASE}/permission_sets/#{@set_b.uuid}/resources"
        assert_response :not_found

        get "#{BASE}/permission_sets/#{@set_b.uuid}/resources/#{@resource_b.uuid}/fields"
        assert_response :not_found

        get "#{BASE}/permission_sets/#{@set_b.uuid}/resources/#{@resource_b.uuid}/rules/#{@rule_b.uuid}"
        assert_response :not_found

        patch "#{BASE}/permission_sets/#{@set_b.uuid}/resources/#{@resource_b.uuid}/fields/#{@field_b.uuid}",
              params: { resource_field: { read_access: false } }
        assert_response :not_found
      end

      test 'created records are stamped with the current tenant' do
        post "#{BASE}/permission_sets", params: { permission_set: { name: 'Created in A' } }
        assert_response :created
        assert_equal @tenant_a.id, PermissionForge::PermissionSet.find_by!(uuid: json.dig('data', 'uuid')).account_id

        post "#{BASE}/permission_sets/#{@set_a.uuid}/resources", params: { resource: { name: 'Supplier', read_access: true } }
        assert_response :created
        assert_equal @tenant_a.id, PermissionForge::Resource.find_by!(uuid: json.dig('data', 'uuid')).account_id
      end

      test 'assignments cannot target another tenant permission set' do
        post "#{BASE}/permission_sets/#{@set_b.uuid}/users", params: { user_id: @user.id }
        assert_response :not_found

        post "#{BASE}/permission_sets/#{@set_b.uuid}/users/bulk", params: { user_ids: [@user.id], bulk_action: 'assign' }
        assert_response :not_found

        delete "#{BASE}/permission_sets/#{@set_b.uuid}/users/#{@assignment_b.uuid}"
        assert_response :not_found

        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'an assignment created through the API is stamped with the tenant and grants only there' do
        post "#{BASE}/permission_sets/#{@set_a.uuid}/users", params: { user_id: @user.id }
        assert_response :created

        assignment = PermissionForge::PermissionSetUser.find_by!(uuid: json.dig('data', 'uuid'))
        assert_equal @tenant_a.id, assignment.account_id
        assert @user.can_read?(:Customer)
        within(@tenant_b) { assert_not @user.can_read?(:Customer) }
      end

      test 'stats are counted per tenant' do
        get "#{BASE}/stats"
        assert_response :ok
        assert_equal 1, json.dig('data', 'permission_sets_count')
        assert_equal 0, json.dig('data', 'users_count')
        assert_equal 0, json.dig('data', 'groups_count')

        ActsAsTenant.test_tenant = @tenant_b
        get "#{BASE}/stats"
        assert_equal 1, json.dig('data', 'permission_sets_count')
        assert_equal 1, json.dig('data', 'users_count')
        assert_equal 1, json.dig('data', 'rules_count')
        assert_equal 1, json.dig('data', 'groups_count')
      end

      test 'group endpoints are isolated per tenant' do
        get "#{BASE}/permission_set_groups"
        assert_response :ok
        assert_empty json['data']

        get "#{BASE}/permission_set_groups/#{@group_b.uuid}"
        assert_response :not_found

        post "#{BASE}/permission_set_groups/#{@group_b.uuid}/users", params: { user_id: @user.id }
        assert_response :not_found
      end

      test 'another tenant group is no permission_set_group_id, by uuid or by id' do
        [@group_b.uuid, @group_b.id].each do |reference|
          patch "#{BASE}/permission_sets/#{@set_a.uuid}", params: { permission_set: { permission_set_group_id: reference } }
          assert_response :unprocessable_entity
          assert_equal [I18n.t('permission_forge.validations.permission_set.group_missing')],
                       json.dig('error', 'messages', 'permission_set_group_id')
        end
        assert_nil @set_a.reload.permission_set_group_id
      end

      private

      def json
        JSON.parse(response.body)
      end
    end
  end
end
