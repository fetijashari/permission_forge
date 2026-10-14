require_relative '../html/admin_test_case'

module PermissionForge
  module Audit
    # T4 through the admin UI: copies credit the acting admin and every delete
    # action leaves a destroy event with a snapshot of the row.
    class ChangeCoverageHtmlTest < Html::AdminTestCase
      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.audit_trail_enabled = true
        PermissionForge.configuration.current_user_resolver = -> { @bo }
        @action = create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        [@set, @resource, @email, @action, @rule].each { |row| row.update_columns(created_by_id: @ana.id, updated_by_id: @ana.id) }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      # --- copies ------------------------------------------------------------------

      test 'duplicate credits the acting admin, unlocks through the create events and records the clone' do
        [@set, @resource, @email, @rule].each { |row| row.update_columns(is_editable: false) }

        assert_no_difference -> { AuditEvent.where(event: %w[resource.updated resource_field.updated permission_set_rule.updated]).count } do
          post pf("/permission_sets/#{@set.id}/duplicate")
        end

        copy = PermissionSet.find_by!(name: 'Sales rep (copy)')
        assert_credited_to_admin(copy)
        assert(copy.resources.first.resource_fields.all?(&:is_editable))
        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, actor_id: @bo.id.to_s,
                                                    data: { 'source_uuid' => @set.uuid })
      end

      test 'start from another set credits the acting admin and records the clone' do
        post pf('/permission_sets'), params: { type: 'granting', name: 'Sales EU', start_from_granting: @set.id }

        copy = PermissionSet.find_by!(name: 'Sales EU')
        assert_credited_to_admin(copy)
        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, actor_id: @bo.id.to_s,
                                                    data: { 'source_uuid' => @set.uuid })
      end

      test 'group duplicate credits the acting admin and records the group and set clones under one id' do
        group = PermissionSetGroup.create!(name: 'Sales', is_active: true, created_by_id: @ana.id)
        @set.update!(permission_set_group: group)

        post pf("/groups/#{group.id}/duplicate")

        copy = PermissionSetGroup.find_by!(name: 'Sales (copy)')
        assert_equal @bo.id, copy.created_by_id
        event = assert_audit_event('permission_set_group.cloned', record_id: copy.id.to_s, actor_id: @bo.id.to_s,
                                                                  data: { 'source_uuid' => group.uuid })
        assert_audit_event('permission_set.cloned', correlation_id: event.correlation_id, data: { 'source_uuid' => @set.uuid })
        assert_credited_to_admin(copy.permission_sets.first)
      end

      # --- deletes -----------------------------------------------------------------

      test 'deleting a Permission Set leaves its snapshot and one for every cascaded row under one id' do
        delete pf("/permission_sets/#{@set.id}")

        destroyed = assert_destroy_snapshot('permission_set.destroyed', @set)
        [['resource.destroyed', @resource], ['resource_field.destroyed', @email], ['resource_action.destroyed', @action],
         ['permission_set_rule.destroyed', @rule], ['assignment.revoked', @assignment]].each do |event, row|
          assert_equal destroyed.correlation_id, assert_destroy_snapshot(event, row).correlation_id, event
        end
      end

      test 'deleting a Resource leaves its snapshot and its children' do
        delete pf("/permission_sets/#{@set.id}/resources/Customer")

        destroyed = assert_destroy_snapshot('resource.destroyed', @resource)
        assert_equal destroyed.correlation_id, assert_destroy_snapshot('resource_field.destroyed', @email).correlation_id
      end

      test 'sync "remove missing fields" leaves a snapshot of every removed field under one id' do
        gone = create_resource_field(resource: @resource, name: 'gone_column')
        also_gone = create_resource_field(resource: @resource, name: 'also_gone')

        post pf("/permission_sets/#{@set.id}/resources/Customer/sync"), params: { op: 'remove_missing' }

        first = assert_destroy_snapshot('resource_field.destroyed', gone)
        second = assert_destroy_snapshot('resource_field.destroyed', also_gone)
        assert_equal first.correlation_id, second.correlation_id
        assert ResourceField.exists?(@email.id)
      end

      test 'deleting an action leaves its snapshot' do
        delete pf("/permission_sets/#{@set.id}/resources/Customer/actions/#{@action.id}")

        assert_destroy_snapshot('resource_action.destroyed', @action)
      end

      test 'deleting a rule leaves its snapshot' do
        delete pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@rule.id}")

        assert_destroy_snapshot('permission_set_rule.destroyed', @rule)
      end

      test 'deleting a group leaves its snapshot and one update per detached set under one id' do
        group = PermissionSetGroup.create!(name: 'Sales', is_active: true)
        @set.update!(permission_set_group: group)

        delete pf("/groups/#{group.id}")

        destroyed = assert_destroy_snapshot('permission_set_group.destroyed', group)
        assert_audit_event('permission_set.updated', record_id: @set.id.to_s, correlation_id: destroyed.correlation_id,
                                                     data: { 'changes' => { 'permission_set_group_id' => [group.id, nil] } })
        assert_nil @set.reload.permission_set_group_id
      end

      # --- Review and save ---------------------------------------------------------

      test 'a Review-and-save that fails validation halfway leaves no events' do
        params = { pf: { set: { description: 'Edited' }, resources: { @resource.id => { create_access: '1' } },
                         fields: { @email.id => { level: 'masked', mask_strategy: 'no_such_strategy' } } } }

        assert_no_difference -> { AuditEvent.count } do
          patch pf("/permission_sets/#{@set.id}/apply"), params: params
        end
        assert flash[:alert].present?
        assert_not @resource.reload.create_access
      end

      test 'a Review-and-save records its changes under one id' do
        params = { pf: { set: { description: 'Edited' }, resources: { @resource.id => { create_access: '1' } } } }

        patch pf("/permission_sets/#{@set.id}/apply"), params: params

        set_event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_id: @bo.id.to_s)
        assert_audit_event('resource.updated', record_id: @resource.id.to_s, correlation_id: set_event.correlation_id)
      end

      private

      def assert_credited_to_admin(set)
        rows = copied_rows(set)
        assert_operator rows.size, :>, 1
        rows.each { |row| assert_row_credited_to_admin(row) }
      end

      def assert_row_credited_to_admin(row)
        name = row.class.name
        assert_equal @bo.id, row.created_by_id, "#{name} keeps the original author"
        assert_equal @bo.id, row.updated_by_id, "#{name} is last edited by the acting admin"
        assert_audit_event("#{row.class.audit_model_key}.created", record_id: row.id.to_s, actor_id: @bo.id.to_s, source: 'admin_ui')
      end

      def copied_rows(set)
        resources = set.resources.to_a
        [set, *resources, *resources.flat_map { |r| r.resource_fields.to_a + r.resource_actions.to_a + r.permission_set_rules.to_a }]
      end

      def assert_destroy_snapshot(event, row)
        found = assert_audit_event(event, record_id: row.id.to_s, actor_id: @bo.id.to_s, source: 'admin_ui')
        assert_equal row.uuid, found.data.dig('snapshot', 'uuid'), "#{event} carries a snapshot of the row"
        found
      end
    end
  end
end
