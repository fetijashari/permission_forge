require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The admin screens a whole-UI test walks: every page, drawer, dialog and
    # audit page of the sample data AdminTestCase sets up. Included by the
    # tests that check every screen (rendering, CSP, accessibility).
    module AdminPagePaths
      extend ActiveSupport::Concern

      included do
        setup do
          @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
          @action = create_resource_action(resource: @resource)
          @group = create_permission_set_group(name: 'Sales')
          @muting = create_permission_set(name: 'Contractors', is_muting: true)
          create_resource(permission_set: @muting, delete_access: true)
        end
      end

      def paths
        people_paths + permission_set_paths(@set.id) + resource_paths("/permission_sets/#{@set.id}/resources/Customer") +
          other_paths + audit_paths
      end

      # The audit log, filtered, one event of each
      # shape (an update's before/after, a destroy's snapshot), and page 2.
      def audit_paths
        @audit_paths ||= begin
          @email.update!(mask_strategy: 'last4')
          updated = PermissionForge::AuditEvent.where(event: 'resource_field.updated').last
          create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Gone').destroy!
          destroyed = PermissionForge::AuditEvent.where(event: 'permission_set_rule.destroyed').last
          audit_event_paths(updated, destroyed)
        end
      end

      def audit_event_paths(updated, destroyed)
        [
          '/audit', "/audit?event=assignment.granted&from=2020-01-01&permission_set=#{@set.id}", '/audit?page=2',
          "/audit?actor_type=user&actor_id=#{@ana.id}&subject_user_id=#{@ana.id}&correlation_id=x&record_type=PermissionForge::PermissionSet&record_id=1",
          "/audit/#{updated.uuid}", "/audit/#{destroyed.uuid}"
        ]
      end

      def people_paths
        person = "/people/#{@ana.id}"
        [
          '/', '/?cleanup=1', '/?privacy=all', '/people', '/people?filter=ending', person,
          "#{person}?tab=effective&why=Customer.read_access", "#{person}?tab=audit",
          "#{person}/remove_all", "#{person}/consent", "#{person}/erasure",
          '/assignments/new', "/assignments/new?user_id=#{@ana.id}", "/assignments/#{@assignment.id}/remove"
        ]
      end

      def permission_set_paths(id)
        [
          '/permission_sets', '/permission_sets?filter=muting', '/permission_sets/new', "/permission_sets/#{id}",
          "/permission_sets/#{id}?tab=assignments", "/permission_sets/#{id}?tab=conditions", "/permission_sets/#{id}?tab=audit",
          "/permission_sets/#{id}/delete", "/permission_sets/#{id}/switch_mode", "/permission_sets/#{@muting.id}",
          "/permission_sets/#{id}/bulk_assignment/new", "/permission_sets/#{id}/bulk_assignment/revoke?user_ids[]=#{@ana.id}",
          "/permission_sets/#{id}/resources/new"
        ]
      end

      def resource_paths(base)
        [
          base, "#{base}?tab=actions", "#{base}?tab=rules", "#{base}/delete", "#{base}/fields/email",
          "#{base}/fields/domain?explain_user_id=#{@ana.id}",
          "#{base}/actions/new", "#{base}/actions/#{@action.id}", "#{base}/actions/#{@action.id}/delete",
          "#{base}/rules/new", "#{base}/rules/#{@rule.id}/edit", "#{base}/rules/#{@rule.id}/delete"
        ]
      end

      def other_paths
        [
          '/field_lookup', '/field_lookup?resource=Customer&field=email', '/groups', '/groups?new=1',
          "/groups/#{@group.id}", "/groups/#{@group.id}/delete", '/settings', '/settings?q=cache&changed=1'
        ]
      end
    end
  end
end
