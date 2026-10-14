module PermissionForge
  module Concerns
    # Cache read/write for user permissions.
    # Provides the shared hash navigation helpers used by ResourcePermissionChecker and FieldMaskChecker.
    #
    # Reads are read-through: a cache miss (first access, TTL expiry, eviction,
    # store flush) transparently rebuilds the hash in the *current* request
    # context, so permission checks never silently operate on an empty hash.
    # Cross-user changes (an admin editing permission records) invalidate the
    # affected users' entries instead of rebuilding them — the rebuild happens
    # lazily in each user's own request.
    #
    # A permission set with activation conditions (session flag, IP
    # allowlist, login hours) counts for the request that READS the hash,
    # never for the one that happened to build it. The entry under the
    # user's key — the base — is built from the unconditional sets and
    # carries the conditional ones with their conditions
    # (PermissionForge::ConditionalSets). Every read evaluates the request
    # context (config.request_context_resolver) against them: when none
    # passes the base is the hash; when some pass, the hash is a variant
    # built from the unconditional sets plus those, under a key derived from
    # the base entry — read from the store, or built read-through and
    # verified against the same invalidation stamp as the base
    # (PermissionsPerContext). A user without conditional sets pays nothing
    # for this: one store read, no resolver call, as before. A resolver that
    # raises (one that reads the request where there is none) raises on
    # every read of a user with conditional sets.
    #
    # A rebuild can race an invalidation: it reads the permission rows, an
    # admin commits and invalidates, and only then does the rebuild store what
    # it read. Each invalidation therefore leaves a per-user stamp in the
    # cache (Cache::Invalidation), and a rebuild only leaves its hash in the
    # cache when the stamp it saw before reading the rows is still there after
    # storing it (Cache::Rebuild). A cache hit never looks at the stamp.
    #
    # Two per-request caches would defeat that check, so a rebuild goes past
    # both: it reads the permission rows outside ActiveRecord's query cache
    # (the repeat would otherwise be answered with the rows of the first
    # attempt) and the stamp outside the cache store's local copy (the second
    # read would otherwise be answered with the first).
    #
    # Inside a database transaction that reads from a snapshot
    # (config.snapshot_transactions) a hash is not shared at all, and the
    # store is not read again by the instance that built it (see
    # regenerate_permissions and PermissionsMemo).
    #
    # Whatever happens to the store, the request that asked gets the hash that
    # was built for it. An empty hash is never a safe substitute: it denies
    # every can_*? check but also empties permission_set_rules, which switches
    # row-level rules off.
    #
    # @api public
    module PermissionCacheAccessor
      extend ActiveSupport::Concern
      include PermissionsMemo
      include PermissionsPerContext

      # Returns the cached permission hash for this user, rebuilding it on a
      # cache miss (read-through).
      #
      # Memoized on the instance: reading from the cache store deserializes the
      # entire hash (for broad grants, a multi-megabyte object graph), and hot
      # paths — MaskedAttributes getters, response filtering, per-field checks —
      # call this method once per attribute. Without a memo each of those calls
      # pays a full store round-trip + deserialize (observed: a 40s admin page).
      # The memo is invalidated by (a) a different permission_cache_key (tenant
      # switch), (b) any bump of PermissionForge.permissions_cache_version —
      # which invalidate_permissions, regenerate_permissions, and cache-store
      # swaps all perform — so no instance in this process can outlive an
      # invalidation with stale data, (c) for a hash that was withheld
      # from the cache inside a transaction, the end of that transaction (or
      # its rollback to a savepoint), and (d) for a user with conditional
      # permission sets, a request context that selects other conditional
      # sets than the memoized hash was built for. #reload also drops it,
      # matching AR's association-cache semantics. See PermissionsMemo.
      #
      # Callers must treat the returned hash as read-only; every call on the
      # same instance returns the same object. Deep-dup before mutating.
      #
      # @return [Hash] the full permission hash including :profile, :preferences, and :permissions
      # @return [Hash] empty hash only when called re-entrantly during its own
      #   rebuild (or when a host override of regenerate_permissions never
      #   reaches the gem's build)
      # @raise [PermissionForge::ConfigurationError] when the request context
      #   resolver reads this user's permissions (PermissionsPerContext)
      def permissions_hash
        key = permission_cache_key
        memo = pf_memoized_permissions(key)
        hash = pf_memoized_permissions_for_context(key, memo) if memo
        return hash if hash

        version = PermissionForge.permissions_cache_version
        selected = pf_shared_or_rebuilt_permissions(key)
        # asked by the build itself (see pf_rebuild_permissions_read_through): {} for that call alone
        return selected.permissions if selected.rebuilt == :reentrant

        pf_memoize_selected_permissions(key, version, selected)
      end

      # Rebuilds and caches the permission hash from all active permission sets:
      # the base entry, and — when the request context selects conditional
      # sets — the variant for them. Returns the hash that applies to the
      # context.
      #
      # The shared cache never keeps a hash that may be older than the latest
      # invalidation (Cache::Rebuild): the entry is checked against the user's
      # invalidation stamp, built once more when an invalidation overtook it,
      # and removed when it cannot be verified.
      #
      # Inside a database transaction that reads from a snapshot
      # (PermissionForge::OpenTransaction.withholding, decided by
      # config.snapshot_transactions) the store is not touched at all. Under
      # REPEATABLE READ or SERIALIZABLE — MySQL's default, and what a SQLite
      # transaction gives — the rows a rebuild reads come from a snapshot
      # that may predate an invalidation that has already finished, so the
      # stamp check would pass on a stale hash. The hash stays on this
      # instance, which does not read the store again until that transaction
      # has ended; another instance of the user goes on reading the entry of
      # the committed rows.
      #
      # Asking for a rebuild says that something changed, though (the way to
      # refresh after update_all, insert_all or delete_all, which run no
      # callbacks). Called inside such a transaction, the user is therefore
      # invalidated once the outermost transaction has committed
      # (Cache::Settlement) — whatever another request cached from the rows as
      # they were before the commit goes with it. A read-through rebuild
      # (a cache miss in permissions_hash) changed nothing: it arranges
      # nothing and retires nobody else's memo.
      #
      # In any other transaction (PostgreSQL at READ COMMITTED) a rebuild
      # reads committed rows plus the transaction's own, and is stored like
      # one outside a transaction — also when the transaction then rolls
      # back: invalidate after a rollback.
      #
      # In every case this instance keeps what it built, for the request that
      # asked: a snapshot a moment old, like any request that finished just
      # before the commit.
      #
      # @return [Hash] the hash that applies to the current request context
      def regenerate_permissions
        PermissionForge::Services::HostKeyGuard.verify!

        key = permission_cache_key
        transaction = PermissionForge::OpenTransaction.withholding
        reading_through = pf_read_through_build(key)
        pf_settle_permissions_after_commit(nil, transaction) unless reading_through

        selected = pf_rebuild_permissions(key, transaction)
        reading_through[:rebuilt] = selected if reading_through

        pf_clear_permissions_memo
        PermissionForge.bump_permissions_cache_version! unless transaction && reading_through
        pf_memoize_permissions(selected.memo(key, PermissionForge.permissions_cache_version))
        # a read-through rebuild is reported by permissions_hash, once memoized
        pf_report_rebuilt(transaction, read_through: false) unless reading_through
        selected.permissions
      end

      # Removes this user's cached permission hash so the next read rebuilds it
      # (read-through) in that request's own context. Removes the ambient key,
      # the tenant-agnostic key, and — when a tenant id is supplied by the
      # caller (e.g., a callback on a tenant-scoped record) — that tenant's key,
      # so background-job invalidations can't desynchronize from web requests;
      # and the keys of the previous entry namespace (Cache::UserKeys).
      # Nothing is read. The per-context variants of a user with conditional
      # sets stay until their TTL: no read can reach them once the base entry
      # that carries their token is gone (ConditionalSets); erasure and
      # cache:clear remove them (Cache::VariantRemoval).
      #
      # A fresh invalidation stamp is written before the keys are removed, one
      # per user whatever the tenant (an invalidation in another tenant makes a
      # rebuild repeat itself, which costs time, not correctness). The store's
      # answers are checked, an unconfirmed invalidation is retried, and one
      # that still fails is reported through Cache::Failure — it does not
      # raise (see Cache::Invalidation).
      #
      # Inside a database transaction that reads from a snapshot
      # (config.snapshot_transactions) the invalidation is made at once and
      # once more when the outermost transaction has committed
      # (Cache::Settlement): between the two, another request can cache the
      # rows as they still are before the commit. This instance does not read
      # the store again until then.
      #
      # @param tenant_id [Object, nil] tenant id of the record that changed, if known
      # @return [Boolean] whether the store confirmed the invalidation
      def invalidate_permissions(tenant_id: nil)
        # the keys and stamp of Cache::UserKeys — shared with the invalidation of many holders by id
        invalidation = PermissionForge::Cache::UserKeys.invalidation(id, tenant_id: tenant_id, ambient_key: permission_cache_key,
                                                                         stamp_key: pf_invalidation_stamp_key)
        confirmed = PermissionForge::Cache::Invalidation.call(**invalidation)
      ensure
        pf_clear_permissions_memo
        PermissionForge.bump_permissions_cache_version!
        # after the invalidation, whatever became of it: the repeat is what counts
        pf_settle_permissions_after_commit(tenant_id)
        # published once the memo and the version are gone: a subscriber that
        # reads permissions_hash gets the state after the invalidation
        PermissionForge::Audit::Runtime.invalidated(self, tenant_id: tenant_id, confirmed: confirmed == true)
      end

      # What the last invalidate_permissions of this user left in the cache
      # (nil when there was none, or it expired), read from the store itself.
      #
      # For a host app that overrides regenerate_permissions to derive a cache
      # entry of its own after `super`: that write races an invalidation the
      # same way. Read the stamp before `super` and again after writing the
      # entry, and delete the entry when the two differ.
      #
      # It lives as long as a hash may: a hash stored without noticing an
      # invalidation would need a rebuild that took longer than cache_ttl, and
      # would expire as soon.
      #
      # @return [String, nil]
      def permission_invalidation_stamp
        PermissionForge.cache.read_fresh(pf_invalidation_stamp_key)
      end

      # The key of this user's base entry in the ambient tenant (or none):
      # "v2:tenant_<tenant id>_user_<id>" / "v2:user_<id>" (Cache::UserKeys).
      #
      # @return [String]
      def permission_cache_key
        PermissionForge::Cache::UserKeys.hash_key(id)
      end

      private

      # The hash for the current request context: from the store, or rebuilt
      # on a miss (and never from the store while this instance withholds).
      #
      # @return [PermissionsPerContext::Selected]
      def pf_shared_or_rebuilt_permissions(key)
        entry = pf_read_shared_permissions(key) unless pf_withholding_permissions?
        (entry && pf_select_shared_permissions(key, entry)) || pf_rebuild_permissions_read_through
      end

      # Memoizes what a read selected, and reports a rebuild. A hash read
      # from the store — or a variant built for a base entry read from it —
      # is memoized under `version`, the one from before the read, so an
      # invalidation during the read retires it. A base rebuilt by
      # regenerate_permissions under the version as it is now: a rebuild
      # that was stored bumps it, which keeps the memo valid until the NEXT
      # invalidation.
      #
      # @return [Hash] the hash
      def pf_memoize_selected_permissions(key, version, selected)
        rebuilt = selected.rebuilt
        version = PermissionForge.permissions_cache_version if rebuilt == :base
        pf_memoize_permissions(selected.memo(key, version))
        # after the memo: building the event finds the hash, not a rebuild
        pf_report_rebuilt(selected.transaction, read_through: true) if rebuilt
        selected.permissions
      end

      # permissions.rebuilt (Audit::Runtime): the hash was built, read-through
      # or on request, inside a withholding transaction or not.
      def pf_report_rebuilt(transaction, read_through:)
        PermissionForge::Audit::Runtime.rebuilt(self, read_through: read_through, withheld: !transaction.nil?)
      end

      # The cached hash — unless this process still owes the store an
      # invalidation of this user (Cache::Backlog). The entry may then be the
      # very one that should be gone, so it is not read: the hash is rebuilt.
      def pf_read_shared_permissions(key)
        return if PermissionForge::Cache::Invalidation.owed?(pf_invalidation_stamp_key)

        PermissionForge.cache.read(key)
      end

      # Inside a transaction whose hashes are withheld: has the user
      # invalidated when it has committed — for the tenant the caller named
      # or the one that is ambient now (the commit may run after the block
      # that made it ambient) — and keeps this instance away from the store
      # until then.
      def pf_settle_permissions_after_commit(tenant_id, transaction = PermissionForge::OpenTransaction.withholding)
        return unless transaction

        pf_withhold_permissions_in(transaction)
        tenant_id ||= PermissionForge.ambient_tenant_id
        PermissionForge::Cache::Settlement.for(transaction).add([:user, id, tenant_id]) do
          invalidate_permissions(tenant_id: tenant_id)
        rescue StandardError => e
          PermissionForge::Cache::Failure.report(operation: :invalidate, user_id: id, error: e)
        end
      end

      def pf_invalidation_stamp_key
        PermissionForge::Cache::UserKeys.stamp_key(id)
      end

      # Rebuilds the hash on a cache miss. Guarded against re-entrancy: building
      # the hash may read attributes on this user (profile_builder, extra fields),
      # and with MaskedAttributes applied those getters consult permissions_hash
      # again — the guard breaks that cycle by returning {} inside the rebuild.
      #
      # The request gets the hash that was built and — when the shared cache
      # kept it — verified, not what the store holds a moment later: another
      # rebuild that raced an invalidation may have its hash there for the
      # instant before it removes it.
      #
      # A call made while the hash for the same key is being built on this
      # thread — by the build's own code: this instance, or another instance
      # of the user whose build reads a masked attribute — is answered {}
      # marked :reentrant, which permissions_hash returns to that call alone
      # and never memoizes. A host override of regenerate_permissions that
      # returns without building the hash for this key raises: {} would deny
      # every check and switch row-level rules off on every call.
      #
      # What the build hands back to this method is kept beside it, on this
      # thread, never on the instance: one user instance may be read on
      # several threads at once (handed to threads of its request, or kept
      # across requests), and their rebuilds would take or clear each other's
      # result — the one that lost it would be left with {}, and keep it.
      #
      # @return [PermissionsPerContext::Selected]
      # @raise [PermissionForge::ConfigurationError] when no hash was built
      def pf_rebuild_permissions_read_through
        key = permission_cache_key
        outcome = pf_guarding_permission_build(key) do |build|
          regenerate_permissions
          # a host override that ran super on another thread or fiber: super memoized it
          build[:rebuilt] || pf_memoized_permissions(key)&.then { |memo| PermissionsPerContext::Selected.of_memo(memo) } ||
            raise(PermissionForge::ConfigurationError,
                  "regenerate_permissions built no permission hash for #{key}: a host override must call super, " \
                  'under the same tenant')
        end
        outcome == :reentrant ? PermissionsPerContext::REENTRANT : outcome
      end

      # Runs a build of the hash for `key` on this thread (fiber), one at a
      # time: a call made while one runs gets :reentrant instead.
      #
      # @yieldparam build [Hash] where regenerate_permissions leaves what it built
      # @return [Object, :reentrant] what the block returns
      def pf_guarding_permission_build(key)
        building = PermissionForge::ExecutionState.fetch(BUILDING_KEY) { {} }
        return :reentrant if building[key]

        build = building[key] = { instance: self }
        begin
          yield build
        ensure
          building.delete(key)
        end
      end

      # The read-through build this instance is making on this thread (fiber)
      # of the hash for `key`, the key regenerate_permissions builds for: an
      # override that changed the tenant before super builds for another key,
      # which fills no build (pf_rebuild_permissions_read_through then raises).
      def pf_read_through_build(key)
        build = PermissionForge::ExecutionState[BUILDING_KEY]&.[](key)
        build if build && build[:instance].equal?(self)
      end

      # Effective TTL for this user's cached hash:
      # - config.cache_ttl as the baseline (default 1 hour),
      # - clamped to conditional_set_cache_ttl when any set has activation
      #   conditions (the backstop for the base entry and its variants),
      # - clamped to the soonest assignment expiry so an expired assignment can
      #   never keep granting from cache beyond its expires_at.
      def pf_permission_cache_ttl(permission_sets, soonest = pf_soonest_assignment_expiry)
        config = PermissionForge.configuration
        [config.cache_ttl, pf_conditional_set_ttl(config, permission_sets), pf_expiry_ttl(soonest)].compact.min
      end

      def pf_conditional_set_ttl(config, permission_sets)
        return nil unless config.conditional_set_cache_ttl && permission_sets.any?(&:conditional?)

        config.conditional_set_cache_ttl
      end

      # When the soonest of the user's active assignments ends (nil: none does).
      #
      # @return [Time, nil]
      def pf_soonest_assignment_expiry
        permission_set_users.active_assignments.where.not(expires_at: nil).minimum(:expires_at)
      end

      # Seconds until `soonest`, so an expired assignment can never keep
      # granting from cache beyond its expires_at.
      def pf_expiry_ttl(soonest)
        [(soonest - Time.current).ceil, 1].max if soonest
      end

      # The active, non-expired sets of the user — every one of them: which
      # of the conditional ones count is decided per read (ConditionalSets).
      #
      # @return [Array<PermissionForge::PermissionSet>]
      def pf_active_non_expired_permission_sets
        active_psu_ids = permission_set_users.active_assignments.select(:permission_set_id)
        # Deterministic order so "first mask_strategy wins" in FieldPermissionMerger
        # is stable across requests and DB adapters (was DB-insertion-order dependent).
        PermissionForge::PermissionSet.active.where(id: active_psu_ids).order(:created_at, :id).to_a
      end

      # The 0.13 name of pf_active_non_expired_permission_sets, kept for host
      # code that calls it with `send` (a hash built by hand, as the cache
      # would hold it). The gem never calls it, so a host method of this name
      # changes nothing here. Drop in 1.0.
      def active_non_expired_permission_sets = pf_active_non_expired_permission_sets

      def pf_resource_name_permissions(resource)
        resource_sym = resource.is_a?(Symbol) ? resource : resource.to_s.to_sym
        permissions_hash.dig(:permissions, :resources, resource_sym)
      end

      def pf_resource_permissions(resource)
        entry = pf_resource_name_permissions(resource)
        return if entry.blank?

        entry[:permissions]
      end
    end
  end
end
