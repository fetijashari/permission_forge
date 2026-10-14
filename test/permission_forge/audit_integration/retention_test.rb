# frozen_string_literal: true

require_relative 'integration_support'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module AuditIntegration
    # Retention: only events strictly older than audit_retention_period go,
    # only in the ambient tenant, never an audit.purged record, never while
    # auditing is off, and every purge records itself — through the service
    # and the rake task.
    class RetentionTest < ActiveSupport::TestCase
      include IntegrationSupport
      include Tenancy::TenancyTestHelper

      NOW = Time.utc(2026, 6, 1, 12, 0, 0)
      PERIOD = 90.days

      setup do
        @admin = create_user(name: ADMIN_NAME)
        @cutoff = NOW - PERIOD
      end

      test 'the purge removes what is strictly older than the period and keeps the boundary' do
        older = old_event(@cutoff - 1.second)
        boundary = old_event(@cutoff)
        newer = old_event(@cutoff + 1.second)

        result = Services::AuditEventPurger.call(older_than: PERIOD, now: NOW, actor: @admin, reason: REASON)

        assert_equal 1, result[:purged]
        assert_not AuditEvent.exists?(older.id)
        assert AuditEvent.exists?(boundary.id), 'an event exactly at the cutoff is kept'
        assert AuditEvent.exists?(newer.id)
        assert_audit_event('audit.purged', actor_id: @admin.id.to_s, source: 'service', reason: REASON,
                                           data: { 'count' => 1, 'cutoff' => @cutoff.iso8601(6), 'period_seconds' => PERIOD.to_i })
      end

      test 'earlier audit.purged records outlive every purge' do
        earlier = Audit.record('audit.purged', data: { 'count' => 3 }, occurred_at: NOW - 3.years)
        old_event(NOW - 2.years)

        Services::AuditEventPurger.call(older_than: PERIOD, now: NOW)

        assert AuditEvent.exists?(earlier.id)
        assert_equal 2, AuditEvent.where(event: 'audit.purged').count
      end

      test 'the purge works in the ambient tenant only' do
        mine = old_event(NOW - 1.year)
        theirs = within(Account.create!(name: 'Other tenant')) { old_event(NOW - 1.year) }

        Services::AuditEventPurger.call(older_than: PERIOD, now: NOW)

        assert_not AuditEvent.exists?(mine.id)
        assert AuditEvent.unscoped.exists?(theirs.id)
      end

      # A platform purge (no tenant) deletes every tenant's events. A tenant
      # auditor never sees an event without a tenant, so each tenant whose
      # events went gets its own audit.purged, with its own count.
      test 'a purge with no tenant records audit.purged in every tenant it purged' do
        other = Account.create!(name: 'Other tenant')
        2.times { old_event(NOW - 1.year) }
        within(other) { old_event(NOW - 1.year) }
        untouched = Account.create!(name: 'Untouched tenant')
        no_tenant!
        old_event(NOW - 1.year) # no tenant at all

        result = Services::AuditEventPurger.call(older_than: PERIOD, now: NOW, actor: @admin)

        purged = AuditEvent.unscoped.where(event: 'audit.purged').to_h { |event| [event.account_id, event.data['count']] }
        assert_equal({ DEFAULT_TEST_ACCOUNT.id => 2, other.id => 1, nil => 1 }, purged)
        assert_equal 4, result[:purged]
        assert_empty within(untouched) { AuditEvent.where(event: 'audit.purged') }
        assert_equal [[1, true]], within(other) { AuditEvent.where(event: 'audit.purged').map { |e| e.data.values_at('count', 'across_tenants') } }
      end

      test 'with no period nothing is purged and nothing is recorded; a dry run only counts' do
        old = old_event(NOW - 10.years)

        assert_no_difference -> { AuditEvent.unscoped.count } do
          assert_not Services::AuditEventPurger.call(older_than: nil, now: NOW)[:retention_configured]
          assert_equal 1, Services::AuditEventPurger.call(older_than: PERIOD, now: NOW, dry_run: true)[:purged]
        end
        assert AuditEvent.exists?(old.id)
      end

      test 'the purge is refused while auditing is off, by the service and the rake task' do
        old = old_event(NOW - 1.year)
        PermissionForge.configuration.audit_events = false

        assert_raises(PermissionForge::ConfigurationError) { Services::AuditEventPurger.call(older_than: PERIOD, now: NOW) }
        _out, err = with_config(:audit_retention_period, PERIOD) do
          with_env('ACTOR' => 'ops') { run_rake_task('permission_forge:audit_events:purge') }
        end

        assert_includes err, 'Refused'
        assert AuditEvent.exists?(old.id)
      end

      test 'rake purge: DRY_RUN=1 deletes nothing, a real run records who ran it' do
        old = old_event(5.years.ago)

        with_config(:audit_retention_period, 1.year) do
          assert_no_difference(-> { AuditEvent.count }) { with_env('DRY_RUN' => '1') { run_rake_task('permission_forge:audit_events:purge') } }
          with_env('ACTOR' => 'ops: retention job', 'REASON' => REASON) { run_rake_task('permission_forge:audit_events:purge') }
        end

        assert_not AuditEvent.exists?(old.id)
        assert_audit_event('audit.purged', actor_type: 'system', actor_label: 'ops: retention job', source: 'rake', reason: REASON,
                                           data: { 'count' => 1 })
      end

      private

      def old_event(at)
        Audit.record('report.generated', data: { 'task' => 'old' }, occurred_at: at)
      end
    end
  end
end
