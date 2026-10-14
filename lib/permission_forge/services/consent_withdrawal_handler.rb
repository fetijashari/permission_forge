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
    #   # => { revoked_sets: 2, invalidated: true }
    #
    # `invalidated` is false when nothing was revoked, and when the cache
    # store did not confirm the invalidation (reported through
    # `config.on_cache_failure`).
    #
    # @example Dry run (inspect without revoking)
    #   result = ConsentWithdrawalHandler.call(
    #     user: user,
    #     consent_flag: 'marketing_consent',
    #     dry_run: true
    #   )
    #   # => { revoked_sets: 0, affected_sets: ["Marketing Access"], dry_run: true }
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
    # cache invalidation runs after the commit (so the summary does not say
    # whether the store confirmed it; the result's `invalidated` does).
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

      # @return [Hash] `{ revoked_sets:, invalidated: }` (plus `affected_sets:` and `dry_run:` for a dry run)
      def call
        validate!

        across_tenants do
          affected_sets = consent_gated_sets
          affected_assignments = user_assignments_for(affected_sets)
          next dry_run_result(affected_sets, affected_assignments) if @dry_run

          audited(actor: @actor, reason: @reason) { withdraw(affected_assignments) }
        end
      end

      private

      def withdraw(affected_assignments)
        revoked_count = ActiveRecord::Base.transaction { revoke_and_record(affected_assignments) }
        # what the store confirmed — not what a host's override of the method returns
        invalidated = revoked_count.positive? && PermissionForge::Cache::Failure.none? { @user.invalidate_permissions }

        { revoked_sets: revoked_count, invalidated: invalidated }
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

      def summary_data(sets, revoked_count)
        {
          'operation' => 'consent_withdrawal',
          'consent_flag' => @consent_flag.to_s,
          'subject_user_id' => @user.id.to_s,
          'set_uuids' => sets.map(&:uuid).uniq,
          'set_names' => sets.map(&:name).uniq,
          'revoked' => revoked_count,
          'dry_run' => false
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

      def dry_run_result(sets, assignments)
        {
          revoked_sets: 0,
          affected_sets: sets.pluck(:name),
          affected_assignment_count: assignments.count,
          dry_run: true
        }
      end
    end
  end
end
