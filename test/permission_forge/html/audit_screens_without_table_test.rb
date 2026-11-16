require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Every admin screen that reads the audit log degrades to a notice when
    # the audit table is not there (an unrun upgrade migration, or
    # audit_events = false on an install that never had it), never a 500.
    class AuditScreensWithoutTableTest < AdminTestCase
      setup do
        admin = create_user(name: 'Ada Admin')
        PermissionForge.configuration.current_user_resolver = -> { admin }
        @table = PermissionForge::AuditEvent.table_name
      end

      def without_audit_table
        connection = PermissionForge::AuditEvent.connection
        connection.rename_table(@table, 'audit_events_hidden')
        forget_table
        yield
      ensure
        connection.rename_table('audit_events_hidden', @table)
        forget_table
      end

      def forget_table
        PermissionForge::AuditEvent.connection.schema_cache.clear!
        PermissionForge::AuditEvent.reset_column_information
        PermissionForge::Audit.reset!
      end

      def assert_missing_table_note
        assert_select '.pf-banner--warn', text: /#{Regexp.escape(I18n.t('permission_forge.audit_log.off.missing_table'))}/
        assert_match 'permission_forge:upgrade', response.body
      end

      test 'the log page and one event show the upgrade notice instead of failing' do
        without_audit_table do
          get pf('/audit')
          assert_response :success
          assert_missing_table_note

          get pf('/audit/abc')
          assert_response :success
          assert_missing_table_note
        end
      end

      test 'the log exports are a 503, the who-holds-what export still works' do
        without_audit_table do
          get pf('/audit.csv')
          assert_response :service_unavailable
          get pf('/audit.json')
          assert_response :service_unavailable
          get pf('/audit/holdings.csv')
          assert_response :success
        end
      end

      test 'the audit tabs of a person and of a Permission Set show the notice' do
        without_audit_table do
          get pf("/people/#{@ana.id}?tab=audit")
          assert_response :success
          assert_missing_table_note

          get pf("/permission_sets/#{@set.id}?tab=audit")
          assert_response :success
          assert_missing_table_note
        end
      end

      test 'with audit_events true the screens still render with the failing notice' do
        PermissionForge.configuration.audit_events = true
        without_audit_table do
          get pf('/audit')
          assert_response :success
          assert_match I18n.t('permission_forge.audit_log.off.failing'), response.body

          get pf("/permission_sets/#{@set.id}?tab=audit")
          assert_response :success
          assert_match I18n.t('permission_forge.audit_log.off.failing'), response.body

          get pf("/permission_sets/#{@set.id}")
          assert_response :success
        end
      end

      test 'with audit_events false the screens say that audit events are turned off' do
        PermissionForge.configuration.audit_events = false
        without_audit_table do
          get pf('/audit')
          assert_response :success
          assert_match I18n.t('permission_forge.audit_log.off.disabled'), response.body

          get pf("/people/#{@ana.id}?tab=audit")
          assert_response :success
          assert_match I18n.t('permission_forge.audit_log.off.disabled'), response.body
        end
      end

      test 'the record pages with an audit footer render without the table' do
        PermissionForge.configuration.audit_events = true
        group = create_permission_set_group(name: 'Team')
        without_audit_table do
          get pf("/permission_sets/#{@set.id}")
          assert_response :success
          get pf("/groups/#{group.id}")
          assert_response :success
        end
      end

      test 'with the table present the log and the tabs list events' do
        PermissionForge::Audit.record('report.generated')

        get pf('/audit')
        assert_response :success
        assert_select '.pf-audit-event'

        get pf("/permission_sets/#{@set.id}?tab=audit")
        assert_response :success
        assert_select '#pf-timeline-title'
        assert_no_match I18n.t('permission_forge.audit_log.off.missing_table'), response.body
      end
    end
  end
end
