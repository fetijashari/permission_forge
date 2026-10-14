# frozen_string_literal: true

module PermissionForge
  module Cache
    # Where a user's permission hash and invalidation stamp live, and what an
    # invalidation of the user removes — one definition for
    # User#invalidate_permissions (PermissionCacheAccessor) and for the
    # invalidation of many holders by id (HolderInvalidation). A key added to
    # one is added to both.
    #
    # The entries live under ENTRY_NAMESPACE ("v2:user_<id>",
    # "v2:tenant_<tenant id>_user_<id>"), bumped when their format changes
    # (0.14: the base entry of a user with conditional sets carries them under
    # :conditional_sets), so that during a rolling deploy a process running
    # another version never reads an entry it would misread. An invalidation
    # removes the keys of the previous namespaces as well
    # (PREVIOUS_ENTRY_NAMESPACES), so a change made through either version
    # reaches both. The stamp is not namespaced: every version must see it.
    #
    # An invalidation removes the base entries, and reads nothing: the
    # per-context variants of a user with conditional sets cannot be reached
    # once the base entry that carries their token is gone, and are left to
    # their TTL (ConditionalSets). Where they must go now — erasure,
    # cache:clear — .variant_removals names them: the index entry of each
    # base entry of this namespace is read (a few bytes, written only for a
    # user who had a variant stored; one call for many users where the store
    # can, Base#read_many), and every slot of a base entry that has one
    # (ConditionalSets.variant_keys) goes with it.
    #
    # @api private
    module UserKeys
      ENTRY_NAMESPACE = 'v2'
      # '' is the bare key of 0.13. Drop in 0.15.
      PREVIOUS_ENTRY_NAMESPACES = [''].freeze

      module_function

      # Every namespace an entry may be under: this version's and the previous ones.
      #
      # @return [Array<String>]
      def namespaces
        [ENTRY_NAMESPACE, *PREVIOUS_ENTRY_NAMESPACES]
      end

      # What the permission entries of a namespace look like, for a store that
      # removes keys by pattern (Base#clear_entries): the keys of every user
      # — any id, a prefixed string one included — tenant-agnostic and per
      # tenant, and their variants. Nothing else of the gem under the bare
      # namespace matches the Regexp: not the stamps (`_invalidation`), not
      # the managed-actions index. The globs, which cannot say "not followed
      # by", take the stamps along with the bare keys. The Regexp starts with
      # `^`, the one anchor ActiveSupport's key_matcher keeps when it puts the
      # store's own namespace in front (a `\A` would be prefixed with `.*`
      # and never match).
      #
      # @param namespace [String]
      # @param prefix [String] the store's key prefix (Base#prefix)
      # @return [Array(Regexp, Array<String>)] the Regexp, and the globs
      def entry_patterns(namespace, prefix:)
        lead = Regexp.escape(entry_lead(namespace, prefix))
        regexp = /^#{lead}(tenant_.+_)?user_(?!.*_invalidation\z).+\z/
        globs = ["#{entry_lead(namespace, prefix)}user_*", "#{entry_lead(namespace, prefix)}tenant_*_user_*"]
        [regexp, globs]
      end

      # Two entries no user can have, one of each key shape, under
      # `namespace`: written before a removal by pattern and read after it,
      # they say whether the pattern reached the store's keys at all
      # (Base#clear_entries).
      #
      # @return [Array<String>] the tenant-agnostic and the tenant key
      def canary_keys(namespace)
        [hash_key(CANARY, nil, namespace: namespace), hash_key(CANARY, CANARY, namespace: namespace)]
      end

      # An id no host key has (not an integer, not a uuid).
      CANARY = 'pf-canary'

      def entry_lead(namespace, prefix)
        namespace.empty? ? "#{prefix}:" : "#{prefix}:#{namespace}:"
      end

      # The key of the user's base entry in a tenant — the ambient one unless
      # named; nil: the tenant-agnostic key — in this namespace
      # (PermissionCacheAccessor#permission_cache_key).
      #
      # @param user_id [Object]
      # @param tenant_id [Object, nil]
      # @param namespace [String] ENTRY_NAMESPACE, or a previous one
      # @return [String]
      def hash_key(user_id, tenant_id = PermissionForge.ambient_tenant_id, namespace: ENTRY_NAMESPACE)
        key = tenant_id ? "tenant_#{tenant_id}_user_#{user_id}" : "user_#{user_id}"
        namespace.empty? ? key : "#{namespace}:#{key}"
      end

      # One per user, whatever the tenant and the version (see Cache::Invalidation).
      #
      # @param user_id [Object]
      # @return [String]
      def stamp_key(user_id)
        "user_#{user_id}_invalidation"
      end

      # The keys a base entry of the user may be under — in the ambient
      # tenant, in no tenant, and in the tenant the caller named (a callback
      # on a tenant-scoped record) — in this namespace, and in the previous
      # ones.
      #
      # @param user_id [Object]
      # @param tenant_id [Object, nil]
      # @param ambient_key [String] the key under the ambient tenant, when
      #   the user instance names its own (#permission_cache_key)
      # @return [Array(Array<String>, Array<String>)] this namespace's keys,
      #   the previous namespaces' keys
      def base_keys(user_id, tenant_id: nil, ambient_key: hash_key(user_id))
        current = ([ambient_key] + [nil, tenant_id].uniq.map { |tenant| hash_key(user_id, tenant) }).uniq
        previous = PREVIOUS_ENTRY_NAMESPACES.flat_map { |namespace| current.map { |key| in_namespace(key, namespace) } }
        [current, previous]
      end

      # `key`, of this namespace, in another one ('' : the bare key of 0.13).
      def in_namespace(key, namespace)
        bare = key.delete_prefix("#{ENTRY_NAMESPACE}:")
        namespace.empty? ? bare : "#{namespace}:#{bare}"
      end

      # The arguments of the user's Invalidation: the stamp, and every key —
      # this namespace's, then the previous namespaces'.
      #
      # @param user_id [Object]
      # @param tenant_id [Object, nil]
      # @param named [Hash] the keys a user instance names itself, when it
      #   does: ambient_key: (#permission_cache_key), stamp_key:
      #   (#pf_invalidation_stamp_key)
      # @return [Hash] user_id:, stamp_key:, keys:
      def invalidation(user_id, tenant_id: nil, **named)
        invalidations([user_id], tenant_id: tenant_id, **named).first
      end

      # The invalidations of many users.
      #
      # @param user_ids [Array]
      # @param tenant_id [Object, nil]
      # @return [Array<Hash>] one per user (see .invalidation)
      def invalidations(user_ids, tenant_id: nil, **named)
        user_ids.map do |user_id|
          current, previous = base_keys(user_id, tenant_id: tenant_id, **named.slice(:ambient_key))
          target(user_id, current + previous, named)
        end
      end

      # The removals of the per-context variants of many users
      # (Cache::VariantRemoval): for each base entry of this namespace, its
      # index entry and every slot (ConditionalSets.variant_keys). With
      # `indexed_only` (cache:clear, many users) only the base entries whose
      # index entry is found — read in one call — and a user none of whose
      # base entries has one is left out. Without it (erasure, one person)
      # nothing is read: a store that fails a read answers "nothing", and the
      # store may have evicted the index entry.
      #
      # @param user_ids [Array]
      # @param tenant_id [Object, nil]
      # @param named [Hash] ambient_key:, stamp_key:, as for .invalidation;
      #   indexed_only: (default true)
      # @return [Array<Hash>] user_id:, stamp_key:, keys: — the arguments of
      #   an Invalidation
      def variant_removals(user_ids, tenant_id: nil, **named)
        keyed = user_ids.map { |user_id| [user_id, base_keys(user_id, tenant_id: tenant_id, **named.slice(:ambient_key)).first] }
        indexes = keyed.flat_map { |_user_id, current| current.map { |key| index_key(key) } }
        found = named.fetch(:indexed_only, true) ? read_indexes(indexes) : EVERY_KEY
        keyed.filter_map do |user_id, current|
          keys = slot_keys(current, found)
          target(user_id, keys, named) if keys.any?
        end
      end

      # Answers every index entry as found.
      EVERY_KEY = Hash.new(true).freeze

      # The arguments of an Invalidation of the user (stamp_key: as named, else the user's own).
      def target(user_id, keys, named)
        { user_id: user_id, stamp_key: named.fetch(:stamp_key) { stamp_key(user_id) }, keys: keys }
      end

      # For each base key whose index entry was found: the index entry and every slot.
      def slot_keys(base_keys, found)
        conditional = PermissionForge::ConditionalSets
        base_keys.select { |key| found[index_key(key)] }.flat_map { |key| [index_key(key), *conditional.variant_keys(key)] }
      end

      def index_key(key)
        PermissionForge::ConditionalSets.index_key(key)
      end

      # A read that raises tells nothing about the index entries: each counts
      # as found, so every slot is removed rather than none.
      #
      # @return [Hash{String => Object}]
      def read_indexes(keys)
        PermissionForge.cache.read_many(keys)
      rescue StandardError
        keys.to_h { |key| [key, true] }
      end
    end
  end
end
