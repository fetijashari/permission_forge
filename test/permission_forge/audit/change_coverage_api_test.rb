require 'test_helper'

module PermissionForge
  module Audit
    # T4 through the JSON API: clones credit the caller and every delete
    # leaves a destroy event with a snapshot of the row.
    class ChangeCoverageApiTest < ActionDispatch::IntegrationTest
      API = '/permission_forge/api'.freeze

      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.audit_trail_enabled = true
        @author = create_user(name: 'Original Author')
        @admin = create_user(name: 'API Admin')
        PermissionForge.configuration.current_user_resolver = -> { @admin }
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email')
        @action = create_resource_action(resource: @resource, name: 'export')
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        [@set, @resource, @field, @action, @rule].each { |row| row.update_columns(created_by_id: @author.id, updated_by_id: @author.id) }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      test 'cloning a Permission Set credits the caller on every copied row and records the clone' do
        post "#{API}/permission_sets/#{@set.uuid}/clone", params: { name: 'API copy' }

        assert_response :created
        copy = PermissionSet.find_by!(name: 'API copy')
        rows = [copy, *copy.resources, *copy.resources.flat_map { |r| r.resource_fields + r.resource_actions + r.permission_set_rules }]
        assert_equal 5, rows.size
        rows.each do |row|
          assert_equal [@admin.id, @admin.id], [row.created_by_id, row.updated_by_id], "#{row.class.name} is credited to the caller"
        end
        assert_audit_event('permission_set.cloned', record_uuid: copy.uuid, actor_id: @admin.id.to_s, source: 'api',
                                                    data: { 'source_uuid' => @set.uuid })
      end

      test 'cloning a group records the group clone and each set clone under one id' do
        group = PermissionSetGroup.create!(name: 'Sales', is_active: true, created_by_id: @author.id)
        @set.update!(permission_set_group: group)

        post "#{API}/permission_set_groups/#{group.uuid}/clone", params: { name: 'Sales API copy' }

        assert_response :created
        copy = PermissionSetGroup.find_by!(name: 'Sales API copy')
        assert_equal @admin.id, copy.created_by_id
        event = assert_audit_event('permission_set_group.cloned', record_uuid: copy.uuid, data: { 'source_uuid' => group.uuid })
        assert_audit_event('permission_set.cloned', correlation_id: event.correlation_id, data: { 'source_uuid' => @set.uuid })
      end

      test 'deleting a Permission Set leaves snapshots of it and its cascaded rows' do
        delete "#{API}/permission_sets/#{@set.uuid}"

        assert_response :no_content
        destroyed = assert_destroy_snapshot('permission_set.destroyed', @set)
        assert_equal destroyed.correlation_id, assert_destroy_snapshot('resource_field.destroyed', @field).correlation_id
      end

      test 'deleting a Resource leaves its snapshot' do
        delete "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}"

        assert_response :no_content
        assert_destroy_snapshot('resource.destroyed', @resource)
        assert_destroy_snapshot('resource_action.destroyed', @action)
      end

      test 'deleting a field, an action and a rule leaves their snapshots' do
        base = "#{API}/permission_sets/#{@set.uuid}/resources/#{@resource.uuid}"
        { 'fields' => ['resource_field.destroyed', @field], 'actions' => ['resource_action.destroyed', @action],
          'rules' => ['permission_set_rule.destroyed', @rule] }.each do |path, (event, row)|
          delete "#{base}/#{path}/#{row.uuid}"

          assert_response :no_content
          assert_destroy_snapshot(event, row)
        end
      end

      test 'deleting a group leaves its snapshot and one update per detached set' do
        group = PermissionSetGroup.create!(name: 'Sales', is_active: true)
        @set.update!(permission_set_group: group)

        delete "#{API}/permission_set_groups/#{group.uuid}"

        assert_response :no_content
        destroyed = assert_destroy_snapshot('permission_set_group.destroyed', group)
        assert_audit_event('permission_set.updated', record_id: @set.id.to_s, correlation_id: destroyed.correlation_id,
                                                     data: { 'changes' => { 'permission_set_group_id' => [group.id, nil] } })
      end

      private

      def assert_destroy_snapshot(event, row)
        found = assert_audit_event(event, record_id: row.id.to_s, actor_id: @admin.id.to_s, source: 'api')
        assert_equal row.uuid, found.data.dig('snapshot', 'uuid'), "#{event} carries a snapshot of the row"
        found
      end
    end
  end
end
