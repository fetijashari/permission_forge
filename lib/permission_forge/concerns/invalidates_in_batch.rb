# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Runs a permission record's cache invalidation after commit, through the
    # InvalidationBatch shared by the records written in the same transaction,
    # so what one of them invalidated is not invalidated again by the next.
    #
    # The including concern or model says what to invalidate by overriding
    # `invalidate_committed_caches` (calling super) and doing the work through
    # `invalidation_batch`:
    #
    #   def invalidate_committed_caches
    #     super
    #     invalidation_batch.once([:my_cache, id]) { MyCache.drop(id) }
    #   end
    #
    # The rule this concern keeps: a record's after_commit reuses a batch only
    # when the record joined it for the write being reported.
    #   - Every write that can lead to after_commit sets the reference first:
    #     save and destroy join the open batch in a before callback (it runs
    #     before the row is written, whatever other callbacks do); touch, which
    #     has no before callback, drops the reference and so invalidates on its
    #     own.
    #   - Every such write also tells the batches of this process to forget
    #     what they remember (InvalidationBatch.note_write): it may be a write
    #     made by a callback between two after_commits of one commit.
    #   - after_commit takes the reference (it is used once) and claims the
    #     batch; a refused claim, or no reference, means a batch of its own.
    #   - Outside after_commit there is no batch to reuse: calling an
    #     invalidation method by hand always invalidates.
    #
    # Two more things hold for every invalidation made here:
    #   - It follows the RECORD's tenant, not the ambient one. A record of
    #     tenant A saved while tenant B (or none) is ambient still finds the
    #     assignments of tenant A (`in_record_tenant`), and their users
    #     whatever default scope the host's user model has.
    #   - Nothing is raised out of after_commit: Rails would skip the commit
    #     callbacks of the remaining records. A failure is reported through
    #     Cache::Failure instead.
    #
    # @api private
    module InvalidatesInBatch
      extend ActiveSupport::Concern

      included do
        before_save :join_invalidation_batch
        before_destroy :join_invalidation_batch
        after_commit :invalidate_after_commit, on: %i[create update destroy]
      end

      def touch(*, **)
        PermissionForge::InvalidationBatch.note_write
        @pf_joined_invalidation_batch = nil
        super
      end

      private

      def join_invalidation_batch
        self.class.connection_pool.with_connection do |connection|
          @pf_joined_invalidation_batch = PermissionForge::InvalidationBatch.join(connection)
        end
      end

      def invalidate_after_commit
        outer = @pf_invalidation_batch
        joined = @pf_joined_invalidation_batch
        @pf_joined_invalidation_batch = nil
        @pf_invalidation_batch = joined&.claim
        invalidate_committed_caches
      rescue StandardError => e
        PermissionForge::Cache::Failure.report(operation: :after_commit, error: e, record: "#{self.class.name}##{id}")
      ensure
        # nil, unless an invalidation wrote this very record again and its
        # commit ran inside this one.
        @pf_invalidation_batch = outer
      end

      # Leaves a note in the batch this record joined for the write in
      # progress, next to the note the record keeps for itself (see
      # InvalidationBatch#note).
      def note_in_invalidation_batch(kind, value)
        @pf_joined_invalidation_batch&.note(kind, value)
      end

      # A record moved by a save (another user, Permission Set or resource)
      # changes what the previous one grants too. Call from after_save: the
      # value `column` had before the save just made is noted when it
      # changed — at every save, since after_commit only sees the last save
      # of a transaction. Like InvalidatesManagedActions' note it is only ever
      # consumed by a commit (#previous_values), never forgotten on rollback
      # (a later save rolled back to a savepoint must not take an earlier
      # move with it; an extra invalidation costs a rebuild), and it is also
      # left in the batch, under the row it belongs to: of two instances of
      # one row written in a transaction, Rails runs the commit callbacks of
      # one.
      def note_previous_value(column)
        return unless has_attribute?(column) && saved_change_to_attribute?(column)

        previous = attribute_before_last_save(column)
        return if previous.nil?

        ((@pf_previous_values ||= {})[column] ||= []) << previous
        note_in_invalidation_batch(:"previous_#{column}", [invalidation_row, previous])
      end

      # The values `column` had before the saves this commit reports — this
      # instance's, and those the batch holds for this row (another instance
      # of it) — consumed: the next commit starts from nothing.
      def previous_values(column)
        own = @pf_previous_values&.delete(column) || []
        row = invalidation_row
        noted = invalidation_batch.noted(:"previous_#{column}").filter_map { |noted_row, value| value if noted_row == row }
        (own + noted).uniq
      end

      # Which row a note in the batch belongs to.
      def invalidation_row
        [self.class.base_class.name, id]
      end

      # What to invalidate once the record's transaction has committed.
      # Override, call super, and work through `invalidation_batch`.
      def invalidate_committed_caches; end

      # The batch of the commit being reported, inside after_commit; anywhere
      # else a batch of its own each time, which remembers nothing.
      def invalidation_batch
        @pf_invalidation_batch || PermissionForge::InvalidationBatch.new
      end

      # Invalidates the cached hash of the users who hold the assignments —
      # once per user and tenant in `batch`. By id, in slices, when nothing
      # but the store calls of User#invalidate_permissions would happen
      # (Cache::HolderInvalidation.by_id?); else through the public
      # User#invalidate_permissions of each loaded user (host apps override
      # it). A user whose invalidation raises is reported and counts as
      # done: the others still get theirs, and the next record of the commit
      # does not try again.
      #
      # @param user_ids [Array] the holders' user ids
      def invalidate_assigned_users(user_ids, batch, tenant_id)
        pending = user_ids.compact.uniq
        pending.reject! { |user_id| batch.done?([:user, user_id, tenant_id]) }
        return if pending.empty?

        if PermissionForge::Cache::HolderInvalidation.by_id?(PermissionForge.configuration.user_model)
          invalidate_user_ids(pending, batch, tenant_id)
        else
          assigned_users(pending).each do |user|
            batch.once([:user, user.id, tenant_id]) { invalidate_user(user, tenant_id) }
          end
        end
      end

      # What the store did not confirm was reported and owed by
      # HolderInvalidation, and counts as done like a user whose
      # invalidate_permissions failed.
      def invalidate_user_ids(user_ids, batch, tenant_id)
        begin
          PermissionForge::Cache::HolderInvalidation.call(user_ids: user_ids, tenant_id: tenant_id)
        rescue StandardError => e
          PermissionForge::Cache::Failure.report(operation: :invalidate, error: e, record: "#{self.class.name}##{id}")
        end
        user_ids.each { |user_id| batch.done!([:user, user_id, tenant_id]) }
      end

      def invalidate_user(user, tenant_id)
        user.invalidate_permissions(tenant_id: tenant_id)
      rescue StandardError => e
        PermissionForge::Cache::Failure.report(operation: :invalidate, user_id: user.id, error: e)
      end

      # Loaded past the default scopes of the host's user model: an ambient
      # tenant, a soft-delete or a permission scope there must not hide the
      # holder of an assignment from an invalidation.
      def assigned_users(user_ids)
        return [] if user_ids.empty?

        model = PermissionForge.configuration.user_model
        PermissionForge::Concerns::AutoPermissionScoping.internally_suspended { model.unscoped.where(model.primary_key => user_ids).to_a }
      end

      # A relation over a permission model that follows this record's tenant
      # instead of the ambient one (HasTenantScoping.of_tenant). The ambient
      # default scope would find nothing for a record of tenant A saved under
      # tenant B, and under no tenant it would also match another tenant's
      # rows that merely share an id. A record without a tenant looks
      # everywhere.
      def in_record_tenant(model)
        model.of_tenant(permission_record_tenant_id)
      end

      # Tenant id of the changed record, so invalidation reaches the
      # tenant-scoped cache key even when no ambient tenant is set
      # (e.g., callbacks fired from a background job).
      def permission_record_tenant_id
        config = PermissionForge.configuration
        return nil unless config.tenant_enabled?

        column = config.resolved_tenant_column
        respond_to?(column) ? public_send(column) : nil
      end
    end
  end
end
