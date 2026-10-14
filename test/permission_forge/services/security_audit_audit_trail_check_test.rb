require 'test_helper'

module PermissionForge
  module Services
    # The audit event log findings of rake permission_forge:audit.
    class SecurityAuditAuditTrailCheckTest < ActiveSupport::TestCase
      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'User'
        @config.http_basic_auth_enabled = false
        @config.audit_actor_resolver = ->(_controller) {}
        @config.audit_runtime_events = %i[denied bypass]
        @config.audit_retention_period = 90.days
      end

      def finding(code, **overrides)
        overrides.each { |key, value| @config.public_send("#{key}=", value) }
        report = SecurityAudit.call(configuration: @config, checks: [SecurityAuditChecks::AuditTrailCheck], environment: 'test')
        report.findings.find { |f| f.code == code }
      end

      def with_missing_table
        original = PermissionForge::AuditEvent.method(:table_exists?)
        replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { false }
        yield
      ensure
        replace_singleton_method(PermissionForge::AuditEvent, :table_exists?, original)
      end

      def event(name, **attrs)
        PermissionForge::AuditEvent.store!({ uuid: SecureRandom.uuid, event: name, category: 'change', actor_type: 'user',
                                             source: 'service', occurred_at: Time.current }.merge(attrs))
      end

      test 'a configured install has no audit findings' do
        report = SecurityAudit.call(configuration: @config, checks: [SecurityAuditChecks::AuditTrailCheck], environment: 'test')

        assert_empty report.findings
      end

      test 'a missing events table is high while auditing is on' do
        with_missing_table do
          assert_equal :high, finding(:audit_table_missing).severity
          assert_nil finding(:audit_table_missing, audit_events: false)
        end
        assert_nil finding(:audit_table_missing)
      end

      test 'a missing table says what each audit_events value does without it' do
        with_missing_table do
          auto = finding(:audit_table_missing, audit_events: :auto)
          assert_match(/audit_events is :auto /, auto.detail)
          assert_match(/no permission change is recorded/, auto.detail)

          strict = finding(:audit_table_missing, audit_events: true)
          assert_match(/audit_events is true /, strict.detail)
          assert_no_match(/:true/, strict.detail)
          assert_match(/every permission change fails/, strict.detail)
          assert_no_match(/no permission change is recorded/, strict.detail)

          reported = finding(:audit_table_missing, audit_events: true, audit_change_failure_strategy: :report)
          assert_match(/goes through unrecorded/, reported.detail)
        end
      end

      test 'a database that cannot be reached is not reported as a missing table' do
        original = PermissionForge::AuditEvent.method(:table_exists?)
        replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { raise ActiveRecord::ConnectionNotEstablished }

        assert_nil finding(:audit_table_missing)
        assert_nil finding(:audit_unknown_actors)
      ensure
        replace_singleton_method(PermissionForge::AuditEvent, :table_exists?, original)
      end

      test 'the unmodified default configuration gets the shared login finding' do
        report = SecurityAudit.call(configuration: PermissionForge::Configuration.new,
                                    checks: [SecurityAuditChecks::AuditTrailCheck], environment: 'test')

        assert_equal :medium, report.findings.find { |f| f.code == :audit_shared_basic_auth }&.severity
      end

      test 'event queries are skipped when the table is missing' do
        with_missing_table { assert_nil finding(:audit_unknown_actors) }
      end

      test 'auditing switched off is high' do
        assert_equal :high, finding(:audit_off, audit_events: false).severity
        assert_nil finding(:audit_off, audit_events: :auto)
      end

      test 'shared basic auth without an actor resolver is medium' do
        found = finding(:audit_shared_basic_auth, http_basic_auth_enabled: true, audit_actor_resolver: nil)

        assert_equal :medium, found.severity
        assert_match(/when current_user_resolver finds nobody/, found.detail)
        assert_nil finding(:audit_shared_basic_auth, http_basic_auth_enabled: true, audit_actor_resolver: ->(_c) {})
        assert_nil finding(:audit_shared_basic_auth, http_basic_auth_enabled: false, audit_actor_resolver: nil)
      end

      test 'an enabled API without an actor resolver records anonymous API clients' do
        found = finding(:audit_anonymous_api, api_enabled: true, audit_actor_resolver: nil)

        assert_equal :medium, found.severity
        assert_equal 'API changes can be recorded as an anonymous API client', found.title
        assert_match(/"API client"/, found.detail)
        assert_nil finding(:audit_anonymous_api, api_enabled: true, audit_actor_resolver: ->(_c) {})
        assert_nil finding(:audit_anonymous_api, api_enabled: false, audit_actor_resolver: nil)
      end

      test 'a refused anonymous API call is not a change with an unknown actor' do
        event('api.auth_failed', category: 'admin', actor_type: 'unknown', source: 'api')
        event('access.denied', category: 'access', actor_type: 'unknown', source: 'runtime')

        assert_nil finding(:audit_unknown_actors)

        event('permission_set.updated', actor_type: 'unknown', source: 'console')
        found = finding(:audit_unknown_actors)
        assert_match(/\A1 change in 30 days has no known actor/, found.title)
      end

      test 'events with an unknown actor in the last 30 days are counted' do
        assert_nil finding(:audit_unknown_actors)
        event('permission_set.updated', actor_type: 'unknown')
        event('permission_set.updated', actor_type: 'unknown')
        event('permission_set.updated', actor_type: 'unknown', occurred_at: 40.days.ago)
        event('permission_set.updated', actor_type: 'user', actor_id: '1')

        found = finding(:audit_unknown_actors)

        assert_equal :medium, found.severity
        assert_match(/\A2 changes in 30 days have no known actor/, found.title)
      end

      test 'an active assignment granted by its own recipient is high, with the people listed' do
        set = create_permission_set
        assert_nil finding(:audit_self_granted)

        user = create_user
        other = create_user
        self_granted = create_permission_set_user(user: user, permission_set: set)
        by_other = create_permission_set_user(user: other, permission_set: set)
        PermissionForge::AuditEvent.where(event: 'assignment.granted').delete_all
        grant(self_granted, actor: user)
        grant(by_other, actor: create_user)

        found = finding(:audit_self_granted)

        assert_equal :high, found.severity
        assert_equal ["user #{user.id}"], found.items
        assert_equal '1 person holds access they granted to themselves', found.title
      end

      test 'a self-granted assignment that was revoked is not reported' do
        set = create_permission_set
        user = create_user
        assignment = create_permission_set_user(user: user, permission_set: set)
        PermissionForge::AuditEvent.where(event: 'assignment.granted').delete_all
        grant(assignment, actor: user)
        assignment.update_columns(expires_at: 1.day.ago)

        assert_nil finding(:audit_self_granted)
      end

      test 'self-granted people are listed up to ten' do
        set = create_permission_set
        12.times do
          user = create_user
          grant(create_permission_set_user(user: user, permission_set: set), actor: user)
        end

        found = finding(:audit_self_granted)

        assert_equal 10, found.items.size
        assert_equal '12 people hold access they granted to themselves', found.title
      end

      test 'only the default runtime group is info' do
        found = finding(:audit_runtime_default, audit_runtime_events: %i[denied])
        assert_equal :info, found.severity
        assert_match(/holds just :denied/, found.detail)
        assert_nil finding(:audit_runtime_default, audit_runtime_events: %i[denied field_read])
      end

      test 'no runtime group at all says so' do
        found = finding(:audit_runtime_default, audit_runtime_events: [])

        assert_equal :info, found.severity
        assert_equal 'No runtime events are stored', found.title
        assert_match(/\ANo runtime events are stored \(audit_runtime_events is empty\)/, found.detail)
        assert_no_match(/:denied/, found.detail.split('.').first)
      end

      test 'a hook failure strategy of log is low' do
        assert_equal :low, finding(:audit_hook_failures_logged, audit_hook_failure_strategy: :log).severity
        assert_nil finding(:audit_hook_failures_logged, audit_hook_failure_strategy: :report)
      end

      test 'a change failure strategy other than raise is medium' do
        assert_equal :medium, finding(:audit_changes_unrecorded, audit_change_failure_strategy: :report).severity
        assert_equal :medium, finding(:audit_changes_unrecorded, audit_change_failure_strategy: :log).severity
        assert_nil finding(:audit_changes_unrecorded, audit_change_failure_strategy: :raise)
      end

      test 'no retention period is info' do
        assert_equal :info, finding(:audit_kept_forever, audit_retention_period: nil).severity
        assert_nil finding(:audit_kept_forever, audit_retention_period: 90.days)
      end

      test 'the check is registered' do
        assert_includes SecurityAudit.checks, SecurityAuditChecks::AuditTrailCheck
      end

      private

      def grant(assignment, actor:)
        event('assignment.granted', actor_type: 'user', actor_id: actor.id.to_s, subject_user_id: assignment.user_id.to_s,
                                    record_type: 'PermissionForge::PermissionSetUser', record_id: assignment.id.to_s)
      end
    end
  end
end
