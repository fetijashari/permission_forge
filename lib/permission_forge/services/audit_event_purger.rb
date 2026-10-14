# frozen_string_literal: true

module PermissionForge
  module Services
    # Retention: deletes audit events older than the retention period and
    # records that it did (`audit.purged`: count, cutoff, period, batch).
    #
    #   AuditEventPurger.call                         # config.audit_retention_period
    #   AuditEventPurger.call(older_than: 400.days, actor: 'nightly job')
    #   AuditEventPurger.call(dry_run: true)          # counts, writes nothing
    #
    # Only events whose `occurred_at` is before now - period are deleted — an
    # event inside the period is never touched, and neither is an
    # `audit.purged` event (the record of purges outlives them). A Duration
    # is subtracted by the calendar (30.days across a DST change, 1.year),
    # a number is seconds. No period (nil: the default) deletes nothing and
    # says so. With auditing off (nothing could record the purge) a real run
    # raises ConfigurationError.
    #
    # Each batch is `delete_all` plus its own `audit.purged` event in ONE
    # transaction: a batch whose event cannot be written is not deleted,
    # under every audit_change_failure_strategy (a purge is always fail-closed),
    # so no deletion is ever unrecorded. In a tenant context only that tenant's events are
    # purged; with none, all of them. A run that finds nothing records nothing.
    #
    # A purge with no tenant (the rake task, a platform job) records one
    # `audit.purged` per tenant whose events the batch deleted, in that
    # tenant and with that tenant's count (`across_tenants: true`), plus one
    # without a tenant for the events that had none: a tenant's auditors
    # never see an event without a tenant, and must still see that their
    # log was purged. Other tenants' counts are not in it.
    #
    # Reached only from Ruby and `rake permission_forge:audit_events:purge`:
    # there is deliberately no controller, route or API for it.
    #
    # @api public
    class AuditEventPurger
      include Concerns::AuditedOperation

      BATCH_SIZE = 1000
      EVENT = 'audit.purged'

      # Deletes audit events past the retention period.
      # @return [Hash] the counts of the run
      def self.call(...) = new(...).call

      # @param older_than [ActiveSupport::Duration, Numeric, nil] the retention period
      # @param actor [Object, nil] a user, an Audit::Actor or a label String
      # @param batch_size [Integer] rows deleted per statement (>= 1)
      # @param now [Time] the clock (tests)
      # @raise [PermissionForge::ConfigurationError] for a period that is not valid
      # @raise [ArgumentError] for a batch_size below 1
      # rubocop:disable-next Metrics/ParameterLists
      def initialize(older_than: PermissionForge.configuration.audit_retention_period, actor: nil, reason: nil,
                     dry_run: false, batch_size: BATCH_SIZE, now: Time.current)
        raise ArgumentError, "batch_size must be at least 1 (got #{batch_size.inspect})" unless batch_size.is_a?(Integer) && batch_size >= 1

        @period = PermissionForge::Configuration::AuditSettings.retention_period(older_than)
        @actor = actor
        @reason = reason
        @dry_run = dry_run
        @batch_size = batch_size
        @now = now
      end

      # @return [Hash] { purged:, retention_configured:, cutoff:, period:, dry_run: } (+ message: when not configured)
      def call
        return not_configured_result if @period.nil?

        cutoff = @now - @period
        return dry_run_result(cutoff) if @dry_run

        refuse_without_auditing!
        audited(actor: @actor, reason: @reason) { purge(cutoff) }
      end

      private

      def dry_run_result(cutoff)
        { purged: expired(cutoff).count, retention_configured: true, cutoff: cutoff, period: @period.to_i, dry_run: true }
      end

      def not_configured_result
        { purged: 0, retention_configured: false, dry_run: @dry_run, message: 'retention not configured' }
      end

      def refuse_without_auditing!
        return if PermissionForge::Audit.enabled?

        raise PermissionForge::ConfigurationError,
              'audit events are switched off (or their table is missing): a purge would be unrecorded, so it is refused'
      end

      def expired(cutoff)
        PermissionForge::AuditEvent.unscoped.in_tenant(PermissionForge.ambient_tenant_id)
                                   .where(PermissionForge::AuditEvent.arel_table[:occurred_at].lt(cutoff))
                                   .where.not(event: EVENT)
      end

      def purge(cutoff)
        purged = 0
        batch = 0
        loop do
          ids = expired(cutoff).order(:id).limit(@batch_size).pluck(:id)
          break if ids.empty?

          batch += 1
          purged += purge_batch(ids, cutoff, batch)
        end

        { purged: purged, retention_configured: true, cutoff: cutoff, period: @period.to_i, dry_run: false }
      end

      # The deletion and its records commit together.
      def purge_batch(ids, cutoff, batch)
        PermissionForge::AuditEvent.transaction do
          per_tenant = counts_by_tenant(ids)
          deleted = PermissionForge::AuditEvent.unscoped.where(id: ids).delete_all
          record_batch(per_tenant || { nil => deleted }, summary_data(cutoff, batch, across_tenants: !per_tenant.nil?))
          deleted
        end
      end

      def record_batch(per_tenant, data)
        per_tenant.each do |tenant_id, count|
          # fail closed whatever audit_change_failure_strategy says: a nil
          # (:report / :log swallowed a failed write) rolls the batch back
          recorded = PermissionForge::Audit.record(EVENT, tenant_id: tenant_id, data: data.merge('count' => count))
          raise PermissionForge::Audit::EventNotRecordedError.new(event: EVENT) if recorded.nil?
        end
      end

      # { tenant id => events of the batch } for a purge with no tenant
      # ambient; nil (one record, in the ambient tenant) otherwise.
      def counts_by_tenant(ids)
        column = PermissionForge::AuditEvent.tenant_column
        return if column.nil? || PermissionForge.ambient_tenant_id

        PermissionForge::AuditEvent.unscoped.where(id: ids).group(column).count
      end

      def summary_data(cutoff, batch, across_tenants:)
        data = { 'operation' => 'audit_events_purge', 'count' => 0, 'batch' => batch,
                 'cutoff' => cutoff.utc.iso8601(6), 'period_seconds' => @period.to_i, 'dry_run' => false }
        data['across_tenants'] = true if across_tenants
        data
      end
    end
  end
end
