require_relative '../cache/report'

module PermissionForge
  module Services
    # Handles consent withdrawal by removing a user from all permission sets
    # gated on the specified consent flag, then invalidating the user's cached
    # permissions (rebuilt read-through on next access).
    #
    # @example Withdraw marketing consent
    #   result = ConsentWithdrawalHandler.call(
    #     user: user,
    #     consent_flag: 'marketing_consent'
    #   )
    #   # => { revoked_sets: 2, invalidated: true, affected_sets: ["Marketing Access", "Newsletter"],
    #   #      affected_assignment_count: 2, dry_run: false,
    #   #      cache: { confirmed: true, process_local: false, unconfirmed: 0 } }
    #
    # `invalidated` is false when nothing was revoked, and when the cache
    # store did not confirm the invalidation (reported through
    # `config.on_cache_failure`). `cache` is the one Cache::Outcome every
    # cache-touching operation answers (Cache::Report): `confirmed` (true
    # also when nothing had to be invalidated), `process_local` (the store
    # lives in this process only: other processes kept their entries),
    # `unconfirmed`. A dry run and a real run answer the same keys:
    # `affected_sets` (the names of the sets gated on the flag),
    # `affected_assignment_count` (this person's assignments to them),
    # `dry_run`; a dry run's `revoked_sets` is 0 and its `invalidated` false.
    #
    # @example Dry run (inspect without revoking)
    #   result = ConsentWithdrawalHandler.call(
    #     user: user,
    #     consent_flag: 'marketing_consent',
    #     dry_run: true
    #   )
    #   # => { revoked_sets: 0, invalidated: false, affected_sets: ["Marketing Access"],
    #   #      affected_assignment_count: 1, dry_run: true, cache: { confirmed: nil, work: false, ... } }
    #
    # The audit log: assignments are destroyed through their callbacks (one
    # `assignment.revoked` each), then ONE `consent.withdrawn` event names the
    # person, the flag, the sets and the counts. `actor:` (a user, an
    # Audit::Actor or a label String) and `reason:` say who ran it and why.
    # A dry run writes nothing.
    #
    # The revocations and `consent.withdrawn` happen in ONE transaction, like
    # DataSubjectErasure: if the summary cannot be written under
    # audit_change_failure_strategy :raise, no assignment is removed. The
    # cache invalidation runs after the commit, so the summary records the
    # outcome as pending (`cache_confirmed: nil`, the store's scope in
    # `process_local`); the result's `invalidated` and `cache` say what the
    # store confirmed.
    #
    # Tenants: with a tenant ambient, the person's assignments in that
    # tenant. With none (a platform task) in every tenant — also under
    # acts_as_tenant's require_tenant — and `consent.withdrawn` is written in
    # each tenant that lost assignments (its sets and count) plus once
    # without a tenant (the totals), each with `across_tenants: true`
    # (Concerns::AcrossTenants).
    #
    # @api public
    class ConsentWithdrawalHandler
      include Concerns::AuditedOperation
      include Concerns::AcrossTenants
      include Concerns::SettlesCache

      # Removes a user from every Permission Set gated on the consent flag.
      # @return [Hash] see {#call}
      def self.call(...) = new(...).call

      def initialize(user:, consent_flag:, dry_run: false, actor: nil, reason: nil)
        @user = user
        @consent_flag = consent_flag
        @dry_run = dry_run
        @actor = actor
        @reason = reason
      end

      # @return [Hash] `{ revoked_sets:, invalidated:, affected_sets:, affected_assignment_count:, dry_run:, cache: }`
      def call
        validate!

        across_tenants do
          affected_sets = consent_gated_sets
          affected_assignments = user_assignments_for(affected_sets)
          found = found(affected_sets, affected_assignments)
          next found.merge(revoked_sets: 0, invalidated: false, cache: PermissionForge::Cache::Report.none.to_h) if @dry_run

          audited(actor: @actor, reason: @reason) { withdraw(affected_assignments).merge(found) }
        end
      end

      private

      def withdraw(affected_assignments)
        @report = PermissionForge::Cache::Report.new
        revoked_count = ActiveRecord::Base.transaction { revoke_and_record(affected_assignments) }
        # what the store confirmed — not what a host's override of the method returns;
        # pending inside a caller's transaction (Report#deferred?)
        outcome = @report.measure { @user.invalidate_permissions if revoked_count.positive? }.outcome
        settle_cache('consent_withdrawal', @user, @report) { @user.invalidate_permissions } if revoked_count.positive?

        { revoked_sets: revoked_count, invalidated: revoked_count.positive? && outcome.confirmed, cache: outcome.to_h }
      end

      def revoke_and_record(affected_assignments)
        assignments = affected_assignments.includes(:permission_set).to_a
        revoked = assignments.select { |assignment| assignment.destroy.present? }
        record_summary(assignments, revoked)
        revoked.size
      end

      # One event, or one per tenant plus the totals (record_per_tenant).
      # Each names the sets of its assignments and counts the revoked ones.
      def record_summary(assignments, revoked)
        record_per_tenant('consent.withdrawn', assignments, subject_user_id: @user.id) do |rows|
          summary_data(rows.filter_map(&:permission_set), rows.count { |row| revoked.include?(row) })
        end
      end

      # The cache outcome is pending here: the invalidation follows the commit.
      def summary_data(sets, revoked_count)
        {
          'operation' => 'consent_withdrawal',
          'consent_flag' => @consent_flag.to_s,
          'subject_user_id' => @user.id.to_s,
          'set_uuids' => sets.map(&:uuid).uniq,
          'set_names' => sets.map(&:name).uniq,
          'revoked' => revoked_count,
          'dry_run' => false,
          **@report.pending.event_data
        }
      end

      def validate!
        raise ArgumentError, 'user is required' if @user.nil?
        raise ArgumentError, 'consent_flag is required' if @consent_flag.blank?
      end

      def consent_gated_sets
        PermissionForge::PermissionSet.where(requires_session_flag: @consent_flag)
      end

      def user_assignments_for(sets)
        PermissionForge::PermissionSetUser.where(user: @user, permission_set: sets)
      end

      # What the run found before it removed anything: the same keys for a
      # dry run and a real one.
      def found(sets, assignments)
        { affected_sets: sets.pluck(:name), affected_assignment_count: assignments.count, dry_run: @dry_run ? true : false }
      end
    end
  end
end
