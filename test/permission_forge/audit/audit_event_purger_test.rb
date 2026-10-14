require 'test_helper'

module PermissionForge
  # T6: retention. Only events older than the period go; the purge records itself.
  class AuditEventPurgerTest < ActiveSupport::TestCase
    setup do
      @marker = "purge-#{SecureRandom.hex(4)}"
      @old = record_at(100.days.ago)
      @edge = record_at(29.days.ago)
      @fresh = record_at(1.hour.ago)
    end

    def record_at(time)
      PermissionForge::Audit.record('report.generated', occurred_at: time, data: { 'marker' => @marker })
    end

    def alive?(event) = PermissionForge::AuditEvent.unscoped.exists?(event.id)

    test 'deletes only events older than the period and records audit.purged afterwards' do
      result = Services::AuditEventPurger.call(older_than: 30.days, actor: 'retention job')

      assert_not alive?(@old)
      assert alive?(@edge)
      assert alive?(@fresh)
      assert result[:retention_configured]
      assert_operator result[:purged], :>=, 1

      event = PermissionForge::AuditEvent.where(event: 'audit.purged').order(:id).last
      assert_equal 'retention job', event.actor_label
      assert_equal result[:purged], event.data['count']
      assert_equal 30.days.to_i, event.data['period_seconds']
      assert_equal result[:cutoff].utc.iso8601(6), event.data['cutoff']
      assert_operator event.occurred_at, :>, result[:cutoff]
    end

    test 'uses config.audit_retention_period by default' do
      PermissionForge.configuration.audit_retention_period = 30.days

      Services::AuditEventPurger.call

      assert_not alive?(@old)
      assert alive?(@edge)
    end

    test 'a nil period deletes nothing, says so and records nothing' do
      assert_nil PermissionForge.configuration.audit_retention_period

      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        result = Services::AuditEventPurger.call

        assert_equal false, result[:retention_configured]
        assert_equal 0, result[:purged]
        assert_equal 'retention not configured', result[:message]
      end
      assert alive?(@old)
    end

    test 'dry run counts and writes nothing' do
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        result = Services::AuditEventPurger.call(older_than: 30.days, dry_run: true)

        assert_operator result[:purged], :>=, 1
        assert result[:dry_run]
      end
      assert alive?(@old)
    end

    test 'deletes in batches' do
      4.times { record_at(200.days.ago) }

      result = Services::AuditEventPurger.call(older_than: 30.days, batch_size: 2)

      assert_operator result[:purged], :>=, 5
      assert_equal 0, PermissionForge::AuditEvent.where(occurred_at: ...30.days.ago).where('data LIKE ?', "%#{@marker}%").count
    end

    test 'a period that is not positive is refused' do
      assert_raises(PermissionForge::ConfigurationError) { Services::AuditEventPurger.call(older_than: 0) }
      assert_raises(PermissionForge::ConfigurationError) { Services::AuditEventPurger.call(older_than: 'soon') }
      assert_raises(PermissionForge::ConfigurationError) { PermissionForge.configuration.audit_retention_period = 'soon' }
      assert_raises(ArgumentError) { Services::AuditEventPurger.call(older_than: 30.days, batch_size: 0) }
    end

    test 'a numeric period is seconds' do
      Services::AuditEventPurger.call(older_than: 30.days.to_i)

      assert_not alive?(@old)
      assert alive?(@edge)
    end

    test 'no route and no controller can trigger a purge' do
      paths = PermissionForge::Engine.routes.routes.map { |route| "#{route.verb} #{route.path.spec}" }
      assert paths.none? { |path| path.match?(/purge|retention/i) }, paths.grep(/purge|retention/i).inspect
      assert(paths.none? { |path| path.match?(/audit_events/) && path.match?(/POST|PATCH|PUT|DELETE/) })
      assert_not(PermissionForge::MaintenanceController.action_methods.any? { |name| name.include?('purge') })
    end

    def failing_summary(pattern)
      klass = PermissionForge::AuditEvent.singleton_class
      klass.alias_method(:__orig_store!, :store!)
      klass.define_method(:store!) do |attrs|
        attrs[:event].match?(pattern) ? raise(ActiveRecord::StatementInvalid, 'boom') : __orig_store!(attrs)
      end
      yield
    ensure
      replace_method(klass, :store!, klass.instance_method(:__orig_store!))
      klass.remove_method(:__orig_store!)
    end

    test 'a batch whose audit.purged cannot be written is not deleted' do
      failing_summary(/\Aaudit\.purged\z/) do
        assert_raises(PermissionForge::Audit::EventNotRecordedError) { Services::AuditEventPurger.call(older_than: 30.days) }
      end

      assert alive?(@old)
    end

    test 'one audit.purged event per batch, in the batch transaction' do
      3.times { record_at(200.days.ago) }
      before = PermissionForge::AuditEvent.where(event: 'audit.purged').count

      result = Services::AuditEventPurger.call(older_than: 30.days, batch_size: 2)

      events = PermissionForge::AuditEvent.where(event: 'audit.purged').order(:id).offset(before)
      assert_equal(result[:purged], events.sum { |e| e.data['count'] })
      assert_equal((1..events.size).to_a, events.map { |e| e.data['batch'] })
      assert_operator events.size, :>=, 2
    end

    test 'audit.purged events are never purged' do
      old_purge = PermissionForge::Audit.record('audit.purged', occurred_at: 400.days.ago, data: {})

      Services::AuditEventPurger.call(older_than: 30.days)

      assert alive?(old_purge)
    end

    test 'a purge with auditing off is refused and deletes nothing' do
      PermissionForge.configuration.audit_events = false

      error = assert_raises(PermissionForge::ConfigurationError) { Services::AuditEventPurger.call(older_than: 30.days) }

      assert_match(/switched off/, error.message)
      assert alive?(@old)
    end

    test 'a day-based period follows the calendar across a DST change' do
      Time.use_zone('Pacific/Auckland') do
        now = Time.zone.local(2026, 4, 10, 12) # NZ DST ended 2026-04-05: 30 days back is 25h + 30 * 24h
        cutoff = now - 30.days
        assert_equal (30 * 86_400) + 3600, (now - cutoff).to_i
        inside = PermissionForge::Audit.record('report.generated', occurred_at: cutoff + 30.minutes, data: {})
        outside = PermissionForge::Audit.record('report.generated', occurred_at: cutoff - 30.minutes, data: {})

        result = Services::AuditEventPurger.call(older_than: 30.days, now: now)

        assert_equal cutoff.to_i, result[:cutoff].to_i
        assert alive?(inside)
        assert_not alive?(outside)
      end
    end

    test 'a year-long period is a calendar year' do
      now = Time.utc(2026, 3, 1)
      leap_edge = PermissionForge::Audit.record('report.generated', occurred_at: Time.utc(2025, 3, 1) - 1.minute, data: {})
      inside = PermissionForge::Audit.record('report.generated', occurred_at: Time.utc(2025, 3, 1) + 1.minute, data: {})

      Services::AuditEventPurger.call(older_than: 1.year, now: now)

      assert_not alive?(leap_edge)
      assert alive?(inside)
    end

    %i[report log].each do |strategy|
      test "a purge is fail-closed under audit_change_failure_strategy #{strategy}" do
        PermissionForge.configuration.audit_change_failure_strategy = strategy

        failing_summary(/\Aaudit\.purged\z/) do
          assert_raises(PermissionForge::Audit::EventNotRecordedError) { Services::AuditEventPurger.call(older_than: 30.days) }
        end

        assert alive?(@old)
      end
    end
  end
end
