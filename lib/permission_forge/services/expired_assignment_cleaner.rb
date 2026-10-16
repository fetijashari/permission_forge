require_relative '../cache/report'

module PermissionForge
  module Services
    # Removes expired PermissionSetUser records and invalidates the cached
    # permissions of all affected users (rebuilt read-through on next access).
    #
    # @example
    #   result = ExpiredAssignmentCleaner.call
    #   # => { removed: 5, invalidated: 3, affected_user_ids: [1, 2, 3], permission_sets: ["Temp"],
    #   #      cache: { confirmed: true, process_local: false, unconfirmed: 0 } }
    #
    # `invalidated` counts the users whose invalidation the cache store
    # confirmed; a failure is reported through `config.on_cache_failure`.
    # `cache` is the one Cache::Outcome every cache-touching operation
    # answers (Cache::Report), and `cleanup.expired_assignments` records the
    # same keys: a store that lives in this process only
    # (Cache::Base#process_local?: an in-memory store) confirms for this
    # process alone — a run from a rake task leaves the web and job
    # processes' entries until they restart or expire (cache_ttl), and the
    # event says `process_local: true`.
    #
    # @example Dry run (inspect without removing)
    #   result = ExpiredAssignmentCleaner.call(dry_run: true)
    #   # => { removed: 0, invalidated: 0, expired_count: 5, affected_user_ids: [1, 2, 3] }
    #
    # Each assignment is re-read, locked, when it is destroyed: one that was
    # renewed (or removed) since the run selected it is left alone, and its
    # `assignment.revoked` snapshot is the row as it was at that moment.
    #
    # The audit log: assignments are destroyed through their callbacks (one
    # `assignment.revoked` each), then ONE `cleanup.expired_assignments` event
    # names the sets and the counts — only when something was removed, so a
    # nightly run over nothing leaves no noise. Its data holds the number of
    # affected users and at most AFFECTED_USER_IDS_LIMIT of their ids
    # (`affected_user_ids_truncated` says when there were more; each
    # `assignment.revoked` names its own user). `actor:` (a user, an
    # Audit::Actor or a label String) and `reason:` say who ran it and why;
    # without a reason (none given, none in the context) the events carry
    # DEFAULT_REASON. A dry run writes nothing.
    #
    # Tenants: with a tenant ambient, that tenant's assignments. With none
    # (the rake task) every tenant's — also under acts_as_tenant's
    # require_tenant — and the summary is written in each tenant that lost
    # assignments (its counts) plus once without a tenant (the totals), each
    # with `across_tenants: true` (Concerns::AcrossTenants).
    #
    # @api public
    class ExpiredAssignmentCleaner
      include Concerns::AuditedOperation
      include Concerns::AcrossTenants

      DEFAULT_REASON = 'expired'.freeze

      # The most user ids the summary event stores: the event's data must
      # stay well inside a MySQL TEXT column (64 KB) whatever the run's size.
      AFFECTED_USER_IDS_LIMIT = 100

      # Removes expired assignments and invalidates the affected users' cached permissions.
      # @return [Hash] see {#call}
      def self.call(...) = new(...).call

      def initialize(dry_run: false, actor: nil, reason: nil)
        @dry_run = dry_run
        @actor = actor
        @reason = reason
        @removed_count = 0
        @invalidated_count = 0
      end

      # @return [Hash] `{ removed:, invalidated:, affected_user_ids:, permission_sets:, cache: }`
      #   (a dry run: `removed: 0, invalidated: 0, expired_count:, affected_user_ids:`)
      def call
        across_tenants do
          expired_records = PermissionForge::PermissionSetUser.expired
          next dry_run_result(expired_records.count, expired_records.distinct.pluck(:user_id)) if @dry_run

          audited(actor: @actor, reason: reason) { clean(expired_records.order(:id).pluck(:id)) }
        end
      end

      private

      def reason
        return @reason if @reason.present? || PermissionForge::Audit::Context[:reason].present?

        DEFAULT_REASON
      end

      def clean(candidate_ids)
        removed = candidate_ids.filter_map { |id| destroy_if_still_expired(id) }
        @removed_count = removed.size
        user_ids = removed.map(&:user_id).uniq

        report = invalidate_users(user_ids)
        confirmed = report.confirmed(user_ids)
        @invalidated_count = confirmed.size
        outcome = report.outcome(user_ids: user_ids)
        sets = sets_of(removed)
        record_summary(removed, sets, confirmed, outcome) if @removed_count.positive?

        { removed: @removed_count, invalidated: @invalidated_count, affected_user_ids: user_ids,
          permission_sets: sets.values.map(&:name).uniq, cache: outcome.to_h }
      end

      # The row as it is now, locked until it is gone; nil when it is no
      # longer expired (renewed) or no longer there.
      def destroy_if_still_expired(id)
        PermissionForge::PermissionSetUser.transaction do
          record = PermissionForge::PermissionSetUser.expired.lock.find_by(id: id)
          record&.destroy
        end
      end

      # @return [Hash{Integer => PermissionSet}] the sets of the removed rows, by id
      def sets_of(records)
        PermissionForge::PermissionSet.where(id: records.map(&:permission_set_id).uniq).index_by(&:id)
      end

      # One event, or one per tenant plus the totals (record_per_tenant),
      # each with the counts of its own rows and the run's cache outcome.
      def record_summary(records, sets, confirmed_user_ids, outcome)
        record_per_tenant('cleanup.expired_assignments', records) do |rows|
          SummaryData.new(rows, sets, confirmed_user_ids, outcome).to_h
        end
      end

      # The data of one cleanup.expired_assignments event, for the removed
      # rows it covers.
      #
      # @api private
      SummaryData = Struct.new(:rows, :sets_by_id, :confirmed_user_ids, :outcome) do
        def to_h
          { 'operation' => 'cleanup_expired_assignments', 'removed' => rows.size,
            'invalidated' => (user_ids & confirmed_user_ids).size, **bounded_user_ids,
            'set_uuids' => sets.map(&:uuid).uniq, 'set_names' => sets.map(&:name).uniq, 'dry_run' => false,
            **outcome.event_data }
        end

        private

        def user_ids
          @user_ids ||= rows.map(&:user_id).uniq
        end

        def sets
          sets_by_id.values_at(*rows.map(&:permission_set_id).uniq.sort).compact
        end

        def bounded_user_ids
          { 'affected_user_count' => user_ids.size,
            'affected_user_ids' => user_ids.first(AFFECTED_USER_IDS_LIMIT).map(&:to_s),
            'affected_user_ids_truncated' => user_ids.size > AFFECTED_USER_IDS_LIMIT }
        end
      end
      private_constant :SummaryData

      def dry_run_result(expired_count, affected_user_ids)
        { removed: 0, invalidated: 0, expired_count: expired_count, affected_user_ids: affected_user_ids }
      end

      # Every affected user's invalidation, measured (Cache::Report): what
      # the store confirmed, per user — not what a host's override of the
      # method returns.
      #
      # @return [PermissionForge::Cache::Report]
      def invalidate_users(user_ids)
        PermissionForge::Cache::Report.measure do
          PermissionForge.configuration.user_model.where(id: user_ids).find_each(&:invalidate_permissions)
        end
      end
    end
  end
end
