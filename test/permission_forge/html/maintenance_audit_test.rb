require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The Home clean-up names the admin who ran it, with nothing passed through the controller.
    class MaintenanceAuditTest < AdminTestCase
      test 'cleanup from home records the summary with the acting admin from the context' do
        @assignment.update_columns(expires_at: 2.days.ago)
        admin = create_user(name: 'Hana Admin')

        previous = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.current_user_resolver = -> { admin }
        delete pf('/maintenance/cleanup')

        event = PermissionForge::AuditEvent.where(event: 'cleanup.expired_assignments').order(:id).last
        assert_equal admin.id.to_s, event.actor_id
        assert_equal 'Hana Admin', event.actor_label
      ensure
        PermissionForge.configuration.current_user_resolver = previous
      end
    end
  end
end
