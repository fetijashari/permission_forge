# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # The is_editable lock covers what a record holds, in the API as in the
    # admin: a locked Permission Set cannot gain or lose resources, fields,
    # rules, actions or holders; a locked Resource cannot gain or change its
    # fields, rules and actions; a locked Permission Set Group cannot gain or
    # lose members or sets. Every refusal is a 403 with admin.lock_refused.
    class HierarchicalLockApiTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      ROOT = '/permission_forge/api'

      setup do
        @set = create_permission_set(name: 'Seeded')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @action = create_resource_action(resource: @resource)
        @user = create_user
        @holder = create_user
        @assignment = create_permission_set_user(user: @holder, permission_set: @set)
        @group = create_permission_set_group(name: 'System')
        @member = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @holder)
      end

      def lock(record)
        record.update!(is_editable: false)
      end

      def set_path = "#{ROOT}/permission_sets/#{@set.uuid}"
      def resource_path = "#{set_path}/resources/#{@resource.uuid}"

      def assert_locked_out(&)
        assert_no_changes -> { snapshot } do
          assert_difference -> { PermissionForge::AuditEvent.where(event: 'admin.lock_refused').count }, 1, &
        end
        assert_response :forbidden
      end

      def snapshot
        [PermissionForge::Resource.count, PermissionForge::ResourceField.count, PermissionForge::PermissionSetRule.count,
         PermissionForge::ResourceAction.count, PermissionForge::PermissionSetUser.count,
         PermissionForge::PermissionSetGroupUser.count, @resource.reload.attributes, @field.reload.attributes,
         PermissionForge::PermissionSet.where(permission_set_group_id: @group.id).count]
      end

      # --- a locked Permission Set ------------------------------------------------

      test 'a locked set gains no resource' do
        lock(@set)
        assert_locked_out { post "#{set_path}/resources", params: { resource: { name: 'Supplier', view_all: true, read_access: true } } }
      end

      test 'a locked set: its resources cannot be changed or deleted' do
        lock(@set)
        assert_locked_out { patch resource_path, params: { resource: { view_all: true } } }
        assert_locked_out { delete resource_path }
      end

      test 'a locked set: no field, rule or action is added under its resources' do
        lock(@set)
        assert_locked_out { post "#{resource_path}/fields", params: { resource_field: { name: 'phone', read_access: true } } }
        assert_locked_out do
          post "#{resource_path}/rules", params: { permission_set_rule: { name: 'r', field_name: 'name', operator: 'is_not_null' } }
        end
        assert_locked_out { post "#{resource_path}/actions", params: { resource_action: { name: 'merge', is_permitted: true } } }
      end

      test 'a locked set: its fields, rules and actions cannot be changed or deleted' do
        lock(@set)
        assert_locked_out { patch "#{resource_path}/fields/#{@field.uuid}", params: { resource_field: { read_access: false } } }
        assert_locked_out { delete "#{resource_path}/rules/#{@rule.uuid}" }
        assert_locked_out { patch "#{resource_path}/actions/#{@action.uuid}", params: { resource_action: { is_permitted: true } } }
        assert_locked_out { delete "#{resource_path}/actions/#{@action.uuid}" }
      end

      test 'a locked set: generate_fields is refused' do
        lock(@set)
        assert_locked_out { post "#{resource_path}/generate_fields" }
      end

      test 'a locked set gains no holder, singly or in bulk' do
        lock(@set)
        assert_locked_out { post "#{set_path}/users", params: { user_id: @user.id } }
        assert_locked_out { post "#{set_path}/users/bulk", params: { user_ids: [@user.id], bulk_action: 'assign' } }
      end

      test 'holders can always be revoked from a locked set (revocation narrows access)' do
        lock(@set)
        other = create_user
        create_permission_set_user(user: other, permission_set: @set)

        assert_no_difference -> { PermissionForge::AuditEvent.where(event: 'admin.lock_refused').count } do
          delete "#{set_path}/users/#{@assignment.uuid}"
          assert_response :no_content
          post "#{set_path}/users/bulk", params: { user_ids: [other.id], bulk_action: 'revoke' }
          assert_response :ok
        end
        assert_equal 1, response.parsed_body.dig('data', 'revoked')
        assert_not PermissionForge::PermissionSetUser.exists?(permission_set_id: @set.id)
      end

      # --- a locked Resource ---------------------------------------------------------

      test 'a locked resource gains no field, rule or action, and its fields do not change' do
        lock(@resource)
        assert_locked_out { post "#{resource_path}/fields", params: { resource_field: { name: 'phone', read_access: true } } }
        assert_locked_out do
          post "#{resource_path}/rules", params: { permission_set_rule: { name: 'r', field_name: 'name', operator: 'is_not_null' } }
        end
        assert_locked_out { post "#{resource_path}/actions", params: { resource_action: { name: 'merge', is_permitted: true } } }
        assert_locked_out { patch "#{resource_path}/fields/#{@field.uuid}", params: { resource_field: { read_access: false } } }
      end

      # --- a locked Permission Set Group ------------------------------------------------

      test 'a locked group gains and loses no member' do
        lock(@group)
        group_path = "#{ROOT}/permission_set_groups/#{@group.uuid}"
        assert_locked_out { post "#{group_path}/users", params: { user_id: @user.id } }
        assert_locked_out { delete "#{group_path}/users/#{@member.uuid}" }
      end

      test 'a set cannot be moved into or out of a locked group' do
        lock(@group)
        assert_locked_out { patch set_path, params: { permission_set: { permission_set_group_id: @group.id } } }
        assert_locked_out { post "#{ROOT}/permission_sets", params: { permission_set: { name: 'New', permission_set_group_id: @group.id } } }

        @set.update_columns(permission_set_group_id: @group.id)
        assert_locked_out { patch set_path, params: { permission_set: { permission_set_group_id: nil } } }
      end

      test 'a set in a locked group is not deleted (the group keeps its list of sets)' do
        @set.update!(permission_set_group: @group)
        lock(@group)

        assert_locked_out { delete set_path }
        assert PermissionForge::PermissionSet.exists?(@set.id)
      end

      test 'a clone of a set in a locked group lands outside the group, editable' do
        @set.update!(permission_set_group: @group)
        lock(@group)

        post "#{set_path}/clone", params: { name: 'Copy' }

        assert_response :created
        assert_nil response.parsed_body.dig('data', 'permission_set_group_id')
        assert_equal 1, PermissionForge::PermissionSet.where(permission_set_group_id: @group.id).count
      end

      test 'a clone of a locked set is an editable copy, as the admin duplicate makes' do
        lock(@set)
        lock(@resource)

        post "#{set_path}/clone", params: { name: 'Copy' }

        assert_response :created
        copy = PermissionForge::PermissionSet.find_by!(uuid: response.parsed_body.dig('data', 'uuid'))
        assert copy.is_editable
        assert(copy.resources.all?(&:is_editable))
      end

      test 'a clone of a locked group is an editable group' do
        lock(@group)

        post "#{ROOT}/permission_set_groups/#{@group.uuid}/clone", params: { name: 'Copy' }

        assert_response :created
        assert PermissionForge::PermissionSetGroup.find_by!(uuid: response.parsed_body.dig('data', 'uuid')).is_editable
      end

      test 'a clone of a locked group copies its sets as editable sets too' do
        @set.update!(permission_set_group: @group)
        lock(@set)
        lock(@group)

        post "#{ROOT}/permission_set_groups/#{@group.uuid}/clone", params: { name: 'Copy' }

        copy = PermissionForge::PermissionSetGroup.find_by!(uuid: response.parsed_body.dig('data', 'uuid'))
        assert_equal ['Seeded'], copy.permission_sets.map(&:name)
        assert(copy.permission_sets.all?(&:is_editable))
        assert(copy.permission_sets.flat_map(&:resources).all?(&:is_editable))
      end

      test 'a clone name that is not text falls back to the default name, and NULs are dropped' do
        post "#{set_path}/clone", params: { name: { 'a' => '1' } }
        assert_equal 'Seeded (Copy)', response.parsed_body.dig('data', 'name')
        post "#{set_path}/clone", params: { name: "Co\u0000py" }
        assert_equal 'Copy', response.parsed_body.dig('data', 'name')
        post "#{ROOT}/permission_set_groups/#{@group.uuid}/clone", params: { name: ['x'] }
        assert_equal 'System (Copy)', response.parsed_body.dig('data', 'name')
      end

      # --- unlocked records are unaffected ------------------------------------------------

      test 'unlocked records still take children, holders and members' do
        post "#{resource_path}/fields", params: { resource_field: { name: 'phone', read_access: true } }
        assert_response :created
        post "#{set_path}/users", params: { user_id: @user.id }
        assert_response :created
        delete "#{set_path}/users/#{@assignment.uuid}"
        assert_response :no_content
        post "#{ROOT}/permission_set_groups/#{@group.uuid}/users", params: { user_id: @user.id }
        assert_response :created
        patch set_path, params: { permission_set: { permission_set_group_id: @group.id } }
        assert_response :ok
      end
    end
  end
end
