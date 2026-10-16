require_relative 'admin_test_case'
require_relative 'admin_paths'

module PermissionForge
  module Html
    # The admin screens a whole-UI test walks (AdminPaths, on the sample data
    # AdminTestCase sets up plus a muting set, a group, an action, a locked set
    # down to its field and rule, and a rule whose column is misspelled).
    # Included by the tests that check every screen (rendering, CSP,
    # accessibility, layout) and every error state.
    module AdminPagePaths
      extend ActiveSupport::Concern

      included do
        setup do
          @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
          @action = create_resource_action(resource: @resource)
          @group = create_permission_set_group(name: 'Sales')
          @muting = create_permission_set(name: 'Contractors', is_muting: true)
          create_resource(permission_set: @muting, delete_access: true)
          @locked = create_permission_set(name: 'Managed by API', is_editable: false)
          locked_resource = create_resource(permission_set: @locked, is_editable: false)
          create_resource_field(resource: locked_resource, is_editable: false)
          create_permission_set_rule(permission_set: @locked, resource: locked_resource, is_editable: false)
          @broken = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Typo rule',
                                               field_name: 'name', field_value: 'active')
          @broken.update_columns(field_name: 'stauts')
        end
      end

      def paths = admin_paths.paths
      def error_states = admin_paths.error_states
      def flows = admin_paths.flows

      # Built once per test: the audit fixtures (an update's before/after, a
      # destroy's snapshot) are recorded on the first use.
      def admin_paths
        @admin_paths ||= begin
          updated, destroyed = audit_fixtures
          AdminPaths.new(ana: @ana.id, assignment: @assignment.id, set: @set.id, muting: @muting.id, locked: @locked.id,
                         group: @group.id, action: @action.id, rule: @rule.id, broken: @broken.id,
                         updated_event: updated.uuid, destroyed_event: destroyed.uuid)
        end
      end

      private

      def audit_fixtures
        @email.update!(mask_strategy: 'last4')
        updated = PermissionForge::AuditEvent.where(event: 'resource_field.updated').last
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Gone').destroy!
        destroyed = PermissionForge::AuditEvent.where(event: 'permission_set_rule.destroyed').last
        [updated, destroyed]
      end
    end
  end
end
