# frozen_string_literal: true

require 'active_support/current_attributes'

module PermissionForge
  module ControllerActions
    # Which resources and custom actions any Permission Set manages.
    #
    # "Managed" means a row is in effect — an active row in an active resource
    # of an active Permission Set, granting or muting — in the current tenant
    # (Resource.in_effect / ResourceAction.in_effect). The guard uses it to tell
    # "nobody has configured this" (unconfigured_action_strategy applies) from
    # "configured, and this user was not granted it" (denied).
    #
    # The index is one small hash ({ 'Customer' => ['export', 'merge'] }) kept
    # in PermissionForge.cache, so every process sees an invalidation
    # (InvalidatesManagedActions drops it when a defining record changes).
    #
    # A stale "not managed" lets a request through under the :allow strategy
    # (under :block, the default, both answers refuse), so the index is
    # invalidated and rebuilt the way a user's permission hash is — the same
    # code, one definition:
    #   - every invalidation leaves a fresh stamp (STAMP_KEY) before it removes
    #     the keys, and a build only leaves the index in the store when the
    #     stamp it read before reading the rows is still there after storing it
    #     (Cache::Invalidation, Cache::Rebuild). A build that raced a commit is
    #     removed and made once more; it reads the rows past ActiveRecord's
    #     query cache;
    #   - a removal the store does not confirm is tried again, reported
    #     (Cache::Failure) and owed by this process (Cache::Backlog): until the
    #     store confirms it, this process builds the index from the database
    #     instead of reading it from the store;
    #   - the cached copy lives at most MAX_TTL seconds, whatever cache_ttl is.
    #     That bounds what nothing above can see: rows changed behind the
    #     callbacks (update_all), and — in the other processes, which do not
    #     know what this one owes — an index whose removal the store never
    #     confirmed;
    #   - a request keeps its own copy (RequestMemo), so many checks in one
    #     request cost one cache read. Rails resets it between requests and
    #     jobs; it is dropped on this thread by invalidate! and re-read after
    #     MAX_TTL in a long-lived process.
    class ManagedIndex
      CACHE_KEY = 'managed_actions'

      # The invalidation stamp: one for every tenant's index, as a user has one
      # whatever the tenant (an invalidation in another tenant makes a build
      # repeat itself, which costs time, not correctness).
      STAMP_KEY = 'managed_actions_invalidation'

      # Rebuilding costs two small queries, so the index can afford to be fresh.
      MAX_TTL = 60

      # The current request's copies: one per cache key, holding the cache
      # version it was read under (a bump replaces it — a job that
      # invalidates many users must not keep one copy per bump).
      class RequestMemo < ActiveSupport::CurrentAttributes
        attribute :indexes
      end

      class << self
        # The managed action keys of a resource, in one lookup. Callers that
        # need both answers (the guard) use this instead of the two predicates.
        #
        # @param resource [String, Symbol] resource name (e.g. 'Customer')
        # @return [Array<String>, nil] nil when no Permission Set manages the resource
        def managed_actions(resource)
          entries[resource.to_s]
        end

        # @param resource [String, Symbol] resource name
        # @return [Boolean]
        def managed_resource?(resource)
          !managed_actions(resource).nil?
        end

        # @param resource [String, Symbol] resource name
        # @param action [String, Symbol] action key (e.g. 'export')
        # @return [Boolean]
        def managed_action?(resource, action)
          Array(managed_actions(resource)).include?(action.to_s)
        end

        # Drops the index for the ambient tenant, the tenant-less key and —
        # when the caller knows it (a callback on a tenant-scoped record) —
        # that record's tenant, along with this request's copies.
        #
        # A Cache::Invalidation: a fresh stamp first, then every key, each
        # removal confirmed by the store (Cache::Base#expunge). One the store
        # does not confirm — or that raises — is tried again; when it still
        # fails it is reported through Cache::Failure, not raised, and owed
        # (Cache::Backlog): this process does not read the index from the store
        # until the store has confirmed it. Other processes may serve the old
        # index until it expires: MAX_TTL seconds at most.
        #
        # Inside an open transaction the rows this is about are not visible to
        # anybody else yet, and a request that builds the index right now
        # caches it without them. So the drop is repeated once the outermost
        # transaction has committed (Cache::Settlement).
        #
        # @param tenant_id [Object, nil]
        # @return [Boolean] whether the store confirmed every removal
        def invalidate!(tenant_id: nil)
          keys = [cache_key, CACHE_KEY, (tenant_key(tenant_id) if tenant_id)].compact.uniq
          confirmed = PermissionForge::Cache::Invalidation.call(user_id: nil, stamp_key: STAMP_KEY, keys: keys)
          repeat_after_commit(tenant_id)
          confirmed
        ensure
          RequestMemo.indexes = nil
        end

        private

        def repeat_after_commit(tenant_id)
          transaction = PermissionForge::OpenTransaction.current
          return unless transaction

          # the tenant that is ambient now: the commit may run after the block that made it so
          tenant_id ||= PermissionForge.ambient_tenant_id
          PermissionForge::Cache::Settlement.for(transaction).add([CACHE_KEY, tenant_id]) { invalidate!(tenant_id: tenant_id) }
        end

        # @return [Hash{String => Array<String>}] frozen
        def entries
          key = cache_key
          memo = (RequestMemo.indexes ||= {})
          version = PermissionForge.permissions_cache_version
          held = memo[key]
          return held[:entries] if held && current?(held, version)

          index, transaction = load(key)
          memo[key] = { entries: index, version: version, at: Time.now, transaction: transaction }
          index
        end

        # A request's copy is good under the cache version it was read with,
        # for MAX_TTL — and, when it was built inside a transaction, for as
        # long as that transaction is open.
        def current?(held, version)
          held[:version] == version && Time.now - held[:at] < MAX_TTL && !held[:transaction]&.finished?
        end

        # An index built inside an open transaction holds rows nobody else can
        # see yet, and that a rollback takes back — at every isolation level.
        # It is not written to the store, and the request's copy of it is
        # dropped when that transaction ends.
        #
        # @return [Array(Hash, PermissionForge::OpenTransaction)] the index, and
        #   the open transaction it was built in (nil when it came from the
        #   store or was built outside one)
        def load(key)
          cached = read_shared(key)
          return [normalize(cached), nil] unless cached.nil?

          transaction = PermissionForge::OpenTransaction.current
          [transaction ? build : store_built(key), transaction]
        end

        # The cached index — unless this process still owes the store its
        # removal (Cache::Backlog): the entry may be the very one that should
        # be gone.
        def read_shared(key)
          PermissionForge.cache.read(key) unless PermissionForge::Cache::Invalidation.owed?(STAMP_KEY)
        end

        # Builds the index and leaves it in the store only when no
        # invalidation overtook the build (Cache::Rebuild).
        #
        # @return [Hash] the index as built, whether or not the store kept it
        def store_built(key)
          PermissionForge::Cache::Rebuild.call(key: key, stamp_key: STAMP_KEY, user_id: nil, build: -> { [build, ttl] }).first
        end

        def ttl
          [PermissionForge.configuration.cache_ttl, MAX_TTL].compact.min
        end

        # String keys (the cache symbolizes hash keys on read), frozen so a
        # request's shared copy cannot be changed by a caller.
        def normalize(index)
          index.to_h { |resource, actions| [resource.to_s, Array(actions).map(&:to_s).freeze] }.freeze
        end

        # Reads the rows outside ActiveRecord's query cache: inside a request
        # it would answer a repeated build with the rows the first one read.
        #
        # @return [Hash{String => Array<String>}] frozen
        def build
          PermissionForge::Resource.uncached do
            index = PermissionForge::Resource.in_effect.distinct.pluck(:name).index_with { [] }
            action_pairs.each { |resource, action| index[resource] << action }
            normalize(index)
          end
        end

        def action_pairs
          PermissionForge::ResourceAction.in_effect.distinct
                                         .pluck(PermissionForge::Resource.arel_table[:name],
                                                PermissionForge::ResourceAction.arel_table[:name])
        end

        # Mirrors PermissionCacheAccessor#permission_cache_key: the ambient
        # tenant's key (PermissionForge.ambient_tenant_id, the one reader).
        def cache_key
          tenant_id = PermissionForge.ambient_tenant_id
          tenant_id ? tenant_key(tenant_id) : CACHE_KEY
        end

        def tenant_key(tenant_id)
          "tenant_#{tenant_id}_#{CACHE_KEY}"
        end
      end
    end
  end
end
