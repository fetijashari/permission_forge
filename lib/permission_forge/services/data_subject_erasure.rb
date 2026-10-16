require_relative '../cache/report'

module PermissionForge
  module Services
    # Supports a GDPR Art. 17 (right to erasure) request for a host user.
    # What it removes:
    #   - the person's permission set assignments and group memberships, in
    #     the ambient tenant, each through its callbacks (one audit event per
    #     row);
    #   - the person's cached permissions;
    #   - the person's name labels in the audit log (actor_label on events
    #     they acted in, record_label on events about them): with a tenant
    #     current, in that tenant's events; with none (the rake task, a
    #     platform operator), in every tenant's, events without a tenant
    #     included;
    #   - whatever the host's `on_erasure` callback deletes.
    # What remains, so the log still says what happened:
    #   - every audit event keeps its ids (actor_id, subject_user_id), ip,
    #     request_id, reason and data (snapshots of the removed rows);
    #   - created_by_id / updated_by_id / reviewed_by_id /
    #     sensitive_acknowledged_by_id on rows the person created, edited or
    #     reviewed;
    #   - assignments and memberships in other tenants when a tenant is
    #     current (counted in `assignments_remaining_elsewhere` and
    #     `group_assignments_remaining_elsewhere`);
    #   - the person's own record and data in the host app, unless
    #     `on_erasure` deletes them.
    #
    # @example Full erasure
    #   result = DataSubjectErasure.call(user: user)
    #   # => { assignments_removed: 3, group_assignments_removed: 1, permission_sets: ["Sales"], groups: [],
    #   #      actor_labels_cleared: 2, record_labels_cleared: 6, events_scrubbed: 8, cache_cleared: true,
    #   #      callback_invoked: true, cache: { confirmed: true, process_local: false, unconfirmed: 0 }, ... }
    #
    # `cache_cleared` is false when the cache store did not confirm the
    # removal (it is unreachable, say): the assignments are gone, but the
    # user's cached permissions may live until cache_ttl. The failure is also
    # reported through `config.on_cache_failure`. It is nil when the service
    # is called inside a database transaction: the assignments are only gone
    # for everybody else — and their cached permissions with them — once that
    # transaction has committed, and a failure then is reported through
    # `config.on_cache_failure` alone.
    #
    # `cache` is the one Cache::Outcome every cache-touching operation
    # answers (Cache::Report): `confirmed` (as `cache_cleared`),
    # `process_local`, `unconfirmed`. `cache_cleared` speaks for the store
    # this process reaches. When that store lives in this process only (an
    # in-memory store, Cache::Base#process_local? — `cache_backend = :memory`,
    # or `Rails.cache` a `:memory_store`), a run from a rake task or a console
    # cleared nothing in the web and job processes: they keep the person's
    # cached permissions until they restart or the entries expire
    # (cache_ttl). `erasure.performed` then says `process_local: true`; its
    # `cache_confirmed` is nil, because the event is written in the
    # erasure's transaction and the cache work follows it.
    #
    # @example Dry run (inspect without removing)
    #   result = DataSubjectErasure.call(user: user, dry_run: true)
    #   # => { assignments_count: 3, group_assignments_count: 1, permission_sets: [...],
    #   #      actor_labels_to_clear: 2, record_labels_to_clear: 4, dry_run: true }
    #
    # The audit log (docs/audit-log.md): the rows are destroyed through their
    # callbacks, so each assignment writes its own `assignment.revoked`
    # event; then the personal labels the log holds about the person are
    # cleared and ONE `erasure.performed` event is written. `actor:` (a user,
    # an Audit::Actor or a label String; nil means the actor of the context)
    # and `reason:` say who ran it and why. A dry run writes nothing at all.
    #
    # The row removal, the label scrub and `erasure.performed` happen in ONE
    # transaction: if the summary cannot be written under
    # audit_change_failure_strategy :raise, nothing changed. Under :report or
    # :log the host chose that changes go through when their record fails: the
    # erasure completes without `erasure.performed` (the failure is reported) —
    # the right to erasure is not blocked by the audit write. The cache
    # invalidation and `on_erasure` run after it. Events a callback writes
    # afterwards keep the labels they were given, so a host callback must not
    # create assignments for the erased person.
    #
    # `on_erasure` runs once the erasure is committed for everybody:
    #   - called outside a transaction, right after the erasure; if it
    #     raises, the erasure stands and is recorded, and the error propagates
    #     (`callback_invoked` is true);
    #   - called inside the caller's transaction, after that transaction has
    #     committed (OpenTransaction#after_commit), and never if it rolls
    #     back (`callback_invoked` is nil: only known at the commit). An
    #     error there is logged and reported (Rails.error, `handled: true`,
    #     like every after-commit error the gem catches), not raised: raising
    #     from Rails' commit would skip the after-commit work queued behind
    #     it, the cache invalidations of the caller's other changes included.
    #
    # With no tenant ambient the service runs over every tenant also under
    # acts_as_tenant's require_tenant (Concerns::AcrossTenants).
    #
    # @api public
    class DataSubjectErasure
      include Concerns::AuditedOperation
      include Concerns::AcrossTenants
      include Concerns::SettlesCache

      # The name labels erasure clears, by the count they are reported under.
      LABELS = { actor_labels: :actor_label, record_labels: :record_label }.freeze

      # Erases a user's permission data (GDPR Art. 17).
      # @return [Hash] see {#call}
      def self.call(...) = new(...).call

      def initialize(user:, on_erasure: nil, dry_run: false, actor: nil, reason: nil)
        @user = user
        @on_erasure = on_erasure
        @dry_run = dry_run
        @actor = actor
        @reason = reason
      end

      # @return [Hash] the counts of what was removed and what remains
      def call
        validate!

        across_tenants do
          next dry_run_result if @dry_run

          audited(actor: erased_person_unnamed, reason: @reason) { erase }
        end
      end

      private

      def erase
        @report = PermissionForge::Cache::Report.new
        removed = ActiveRecord::Base.transaction { remove_and_record }
        outcome = clear_cache
        settle_cache('erasure', @user, @report) { remove_user_cache }

        removed.merge(cache_cleared: outcome.confirmed, callback_invoked: run_callback, cache: outcome.to_h)
      end

      def remove_and_record
        sets = permission_set_assignments.includes(:permission_set).filter_map(&:permission_set)
        groups = group_assignments.includes(:permission_set_group).filter_map(&:permission_set_group)

        counts = { assignments_removed: remove_all(permission_set_assignments),
                   group_assignments_removed: remove_all(group_assignments) }
        counts.merge!(remaining_elsewhere)
        scrubbed = scrub_labels
        record_summary(sets, groups, counts, scrubbed)
        counts.merge(result_details(sets, groups, scrubbed))
      end

      # The names removed and the labels cleared, as the result reports them.
      def result_details(sets, groups, scrubbed)
        { permission_sets: sets.map(&:name).uniq, groups: groups.map(&:name).uniq,
          actor_labels_cleared: scrubbed[:actor_labels], record_labels_cleared: scrubbed[:record_labels],
          events_scrubbed: scrubbed.values.sum }
      end

      # What the person still has in other tenants (nothing is removed there).
      def remaining_elsewhere
        {
          assignments_remaining_elsewhere: PermissionForge::PermissionSetUser.unscoped.where(user: @user).count,
          group_assignments_remaining_elsewhere: PermissionForge::PermissionSetGroupUser.unscoped.where(user: @user).count
        }
      end

      # A person who erases themselves must not leave their own name on the
      # events of the erasure: the id stays, the label does not. Without
      # `actor:` the context's actor (the admin of the request) is the one
      # compared.
      def erased_person_unnamed
        resolved = audit_actor_for(@actor) || PermissionForge::Audit::Actor.current
        return @actor unless resolved.type == 'user' && resolved.id == @user.id.to_s

        PermissionForge::Audit::Actor.new(type: resolved.type, id: resolved.id)
      end

      # The only sanctioned mutation of audit events: the snapshots of the
      # person's name. Every id stays, so the trail still says WHAT happened;
      # only WHO (as a name) is forgotten. Past the insert-only guards on
      # purpose (`update_all` is the one path T1 leaves open), in the events
      # of scrubbed_events, only for actors of type 'user' (an API key or a
      # basic auth login that shares the id is somebody else), and recorded
      # in `erasure.performed`.
      def scrub_labels
        {
          actor_labels: labelled(:actor_labels).update_all(actor_label: nil),
          record_labels: labelled(:record_labels).update_all(record_label: nil)
        }
      end

      # The events whose label names the person: as the actor (an actor of
      # type 'user', in actor_label) or as the subject (in record_label).
      def labelled(kind)
        id = @user.id.to_s
        events = if kind == :actor_labels
                   scrubbed_events.where(actor_type: 'user', actor_id: id)
                 else
                   scrubbed_events.where(subject_user_id: id)
                 end
        events.where.not(LABELS.fetch(kind) => nil)
      end

      # With a tenant current (a tenant admin), that tenant's events only: a
      # tenant cannot reach another tenant's log. With none (the rake task, a
      # platform operator), every tenant's, and the events without a tenant.
      # Built on `unscoped` and an explicit tenant condition, so it does not
      # depend on acts_as_tenant's default scope. An events table without the
      # tenant column cannot be told apart by tenant: every event.
      def scrubbed_events
        PermissionForge::AuditEvent.unscoped.in_tenant(PermissionForge.ambient_tenant_id)
      end

      def record_summary(sets, groups, counts, scrubbed)
        PermissionForge::Audit.record('erasure.performed', subject_user_id: @user.id,
                                                           data: summary_data(sets, groups, counts, scrubbed))
      end

      # The cache outcome is pending here: the invalidation follows this
      # transaction (@report.pending: the store's scope, nothing confirmed).
      def summary_data(sets, groups, counts, scrubbed)
        cleared = { 'events_scrubbed' => scrubbed.values.sum, 'actor_labels_cleared' => scrubbed[:actor_labels],
                    'record_labels_cleared' => scrubbed[:record_labels] }
        names(sets, 'set').merge(names(groups, 'group'), counts.transform_keys(&:to_s), cleared,
                                 'operation' => 'erasure', 'subject_user_id' => @user.id.to_s,
                                 'callback_invoked' => !@on_erasure.nil?, 'dry_run' => false,
                                 **@report.pending.event_data)
      end

      def names(records, kind)
        { "#{kind}_uuids" => records.map(&:uuid).uniq, "#{kind}_names" => records.map(&:name).uniq }
      end

      def validate!
        raise ArgumentError, 'user is required' if @user.nil?
      end

      def permission_set_assignments
        PermissionForge::PermissionSetUser.where(user: @user)
      end

      def group_assignments
        PermissionForge::PermissionSetGroupUser.where(user: @user)
      end

      # Destroys the rows through their callbacks (one audit event each).
      #
      # @return [Integer] how many there were
      def remove_all(records)
        count = records.count
        records.destroy_all
        count
      end

      # Measured by Cache::Report (the gem's own failure bookkeeping), not
      # the value of invalidate_permissions: a host app overrides that method.
      #
      # An invalidation leaves the per-context variants of a user with
      # conditional sets to their TTL (unreachable). They hold the profile,
      # so they are removed as well (Cache::VariantRemoval) — inside the
      # caller's transaction once it has committed (SettlesCache runs the
      # work again there, measured, and records cache.settled), after the
      # assignments' own invalidations: until then another request may still
      # cache one from the rows as they were.
      #
      # @return [PermissionForge::Cache::Outcome] confirmed nil inside an
      #   open transaction, where that is only known at its commit
      def clear_cache
        @report.measure do
          invalidate_user
          PermissionForge::Cache::VariantRemoval.call(**variant_removal) unless @report.deferred?
        end
        @report.outcome
      end

      # The person's cache work after a caller's commit: the invalidation and
      # every per-context variant.
      def remove_user_cache
        invalidate_user
        PermissionForge::Cache::VariantRemoval.call(**variant_removal)
      end

      # The arguments of the person's Cache::VariantRemoval: the keys the
      # instance names, as invalidate_permissions removes them, every slot of
      # each without reading the index entries (a read that fails silently
      # and an evicted index entry must not leave a variant behind).
      def variant_removal
        named = @user.respond_to?(:permission_cache_key) ? { ambient_key: @user.permission_cache_key } : {}
        { user_ids: [@user.id], indexed_only: false, **named }
      end

      def invalidate_user
        # invalidate_permissions (not a raw cache delete) so the ambient and
        # tenant-agnostic keys are both removed AND the process-wide memo
        # version bumps — no live instance may keep serving an erased user's
        # permissions from its instance memo.
        return @user.invalidate_permissions if @user.respond_to?(:invalidate_permissions)

        cache = PermissionForge.cache
        key = @user.permission_cache_key
        PermissionForge::Cache::Failure.report(operation: :invalidate, keys: [key]) unless cache.expunge(key)
        PermissionForge.bump_permissions_cache_version!
      end

      # @return [Boolean, nil] false without a callback; true once it ran;
      #   nil when it waits for the caller's transaction to commit
      def run_callback
        return false if @on_erasure.nil?

        transaction = PermissionForge::OpenTransaction.current
        return defer_callback(transaction) if transaction

        @on_erasure.call(@user)
        true
      end

      def defer_callback(transaction)
        callback = @on_erasure
        user = @user
        transaction.after_commit { report_callback_failure { callback.call(user) } }
        nil
      end

      def report_callback_failure
        yield
      rescue StandardError => e
        Rails.logger&.error("[PermissionForge] on_erasure failed after the erasure committed — #{e.class}: #{e.message}")
        Rails.error.report(e, handled: true, source: 'permission_forge.data_subject_erasure')
      end

      # The label counts (actor_labels_to_clear, record_labels_to_clear) are of
      # the events there now — none on an app whose audit table is not there
      # yet; the events the erasure itself writes (assignment.revoked, ...) are
      # cleared as well.
      def dry_run_result
        table = PermissionForge::AuditEvent.table_exists?
        {
          assignments_count: permission_set_assignments.count,
          group_assignments_count: group_assignments.count,
          permission_sets: permission_set_assignments.includes(:permission_set).filter_map { |psu| psu.permission_set&.name },
          **LABELS.keys.to_h { |kind| [:"#{kind}_to_clear", table ? labelled(kind).count : 0] },
          cache: PermissionForge::Cache::Report.none.to_h,
          dry_run: true
        }
      end
    end
  end
end
