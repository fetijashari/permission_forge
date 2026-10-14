# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Which permission hash the request context selects for a user with
    # conditional permission sets (PermissionForge::ConditionalSets): the
    # base entry, or the variant of the conditional sets that pass — on a
    # read (PermissionCacheAccessor#permissions_hash), on a rebuild
    # (regenerate_permissions) — and how each entry, base or variant, is
    # built. (What an invalidation removes is Cache::UserKeys; the variants
    # go on erasure and cache:clear, Cache::VariantRemoval.) A user without
    # conditional sets costs it nothing: one nil check.
    #
    # @api private
    module PermissionsPerContext
      # What a read produced: the hash, what selected it (nil without
      # conditional sets), the open transaction it was built in (nil when it
      # was read from the store, or built outside one), and how it came
      # about — nil: read from the store; :base — regenerate_permissions
      # built it, which bumped the version; :variant — a variant built
      # read-through for a base entry read from the store, which did not;
      # :reentrant — asked by the build itself, {} for that call alone. And
      # when the soonest of the user's assignments that went into it ends
      # (epoch seconds, nil for none: EXPIRY_KEY).
      #
      # @api private
      Selected = Data.define(:permissions, :served, :transaction, :rebuilt, :expires_at) do
        def initialize(expires_at: nil, **)
          super
        end

        # What a memo holds, as a base rebuilt by regenerate_permissions.
        def self.of_memo(memo)
          new(permissions: memo.permissions, served: memo.served, transaction: nil, rebuilt: :base, expires_at: memo.expires_at)
        end

        # @return [PermissionsMemo::Memo] the memo of this hash, good for `version`
        def memo(key, version)
          PermissionsMemo::Memo.new(key: key, version: version, transaction: transaction, permissions: permissions, served: served,
                                    expires_at: expires_at)
        end
      end

      REENTRANT = Selected.new(permissions: {}.freeze, served: nil, transaction: nil, rebuilt: :reentrant)

      # The fiber-local ExecutionState slot of the builds (and request-context
      # resolutions) running on this fiber, by permission cache key.
      BUILDING_KEY = :pf_building_permission_keys

      # Where the stored base entry of a user with an assignment that ends
      # (PermissionSetUser#expires_at) carries when the soonest one ends, in
      # epoch seconds — as it carries the conditional sets: taken off on
      # every read, never part of the hash. The memo of the hash is retired
      # then (PermissionsMemo::Memo#serves?): an instance kept across
      # requests stops granting what the assignment granted when it ends,
      # as the store entry (whose TTL is clamped to it) does.
      EXPIRY_KEY = :assignments_expire_at

      private

      # The memoized hash, while the request context still selects what it
      # was built for. For a user without conditional sets: always. With
      # them: when the context is the one that selected it (its signature,
      # cheap), or another one that selects the same variant — remembered
      # as such, so the next call is cheap again. nil when the context now
      # selects another variant: the base entry is read again.
      #
      # @return [Hash, nil]
      def pf_memoized_permissions_for_context(key, memo)
        again = memo.for_context { pf_resolve_request_context(key) }
        return unless again

        pf_memoize_permissions(again) unless again.equal?(memo)
        again.permissions
      end

      # What a base entry read from the store serves in the current request
      # context: itself — or, when the context selects conditional sets, the
      # variant for them, read from the store (when its slot holds the
      # variant of this base entry and selection:
      # ConditionalSets.variant_hash) or built read-through.
      #
      # @return [Selected, nil] nil for an entry that cannot be used (its
      #   conditional sets cannot be read): a miss
      def pf_select_shared_permissions(key, entry)
        hash, conditional, expires_at = pf_split_base_entry(entry)
        return unless hash
        return pf_read_permissions(hash, nil, expires_at) unless conditional

        served = conditional.serve(pf_resolve_request_context(key))
        variant = served.variant
        return pf_read_permissions(hash, served, expires_at) unless variant

        # a variant that is never stored (ConditionalSets::MAX_CACHED_SETS) is not looked for
        stored = pf_read_shared_permissions(served.store_key(key)) if variant.cached
        cached = PermissionForge::ConditionalSets.variant_hash(stored, variant)
        return pf_read_permissions(cached, served, expires_at) if cached

        pf_rebuild_variant_read_through(key, served, expires_at)
      end

      def pf_read_permissions(hash, served, expires_at)
        Selected.new(permissions: hash, served: served, transaction: nil, rebuilt: nil, expires_at: expires_at)
      end

      # A stored base entry taken apart: the hash in the public format, the
      # conditional sets it carries (ConditionalSets.split) and when the
      # soonest assignment that went into it ends (EXPIRY_KEY).
      #
      # @return [Array(Hash, ConditionalSets|nil, Integer|nil), nil] nil for
      #   an entry that cannot be used
      def pf_split_base_entry(entry)
        expires_at = entry[EXPIRY_KEY]
        hash, conditional = PermissionForge::ConditionalSets.split(expires_at ? entry.except(EXPIRY_KEY) : entry)
        [hash, conditional, (expires_at if expires_at.is_a?(Integer))] if hash
      end

      # Builds the variant `served` names on a cache miss, under the same
      # guard as a read-through rebuild of the base (the build reads this
      # user's attributes too), and stores it unless it is withheld.
      #
      # @return [Selected]
      def pf_rebuild_variant_read_through(key, served, expires_at)
        outcome = pf_guarding_permission_build(key) do
          transaction = PermissionForge::OpenTransaction.withholding
          permissions = pf_rebuild_variant(key, transaction, served)
          Selected.new(permissions: permissions, served: served, transaction: transaction, rebuilt: :variant, expires_at: expires_at)
        end
        outcome == :reentrant ? REENTRANT : outcome
      end

      # Builds the base entry and — when the request context selects
      # conditional sets — the variant for them; stores each unless it is
      # withheld inside a transaction (regenerate_permissions).
      #
      # @return [Selected] the hash that applies to the context, and what
      #   selected it (nil when the user holds no conditional set), as a
      #   base rebuilt
      def pf_rebuild_permissions(key, transaction)
        hash, conditional, expires_at = pf_split_base_entry(pf_rebuild_permission_entry(key, transaction))
        served = conditional&.serve(pf_resolve_request_context(key))
        hash = pf_rebuild_variant(key, transaction, served) if served&.variant
        Selected.new(permissions: hash, served: served, transaction: transaction, rebuilt: :base, expires_at: expires_at)
      end

      # Builds one entry — the base under `key` (served nil), or the variant
      # `served` selects — and, unless it is withheld inside a transaction
      # or not cached at all (Variant#cached), stores it, verified against
      # the user's invalidation stamp. A variant is written only after its
      # index entry (#pf_variant_indexed?), which is written after the
      # stamp was read. The WithheldNotice counts permission rebuilds only
      # (Cache::Rebuild also builds the managed-actions index).
      #
      # @param key [String] the user's base key
      # @param served [ConditionalSets::Served, nil] what selected a variant
      # @return [Hash] the entry as built, with symbol keys like one read
      #   from the store (a variant's: #pf_rebuild_variant)
      def pf_rebuild_permission_entry(key, transaction, served = nil)
        variant = served&.variant
        rebuild = PermissionForge::Cache::Rebuild.new(
          key: served ? served.store_key(key) : key, stamp_key: pf_invalidation_stamp_key, user_id: id,
          build: -> { pf_build_permission_entry(variant) }
        )
        notice = PermissionForge::Cache::WithheldNotice
        transaction ? notice.withheld : notice.not_withheld
        withheld = transaction || (variant && !variant.cached)
        (withheld ? rebuild.withhold : pf_store_rebuild(rebuild, key, served)).deep_symbolize_keys
      end

      # Runs a rebuild that is stored: a variant's after its index entry.
      #
      # @return [Hash] the entry as built
      def pf_store_rebuild(rebuild, key, served)
        return rebuild.call.first unless served&.variant

        rebuild.call { pf_variant_indexed?(key) }.first
      end

      # The hash a variant's rebuild built, without what its entry carries
      # (ConditionalSets.variant_entry; nothing for a variant that is never
      # stored).
      def pf_rebuild_variant(key, transaction, served)
        variant = served.variant
        entry = pf_rebuild_permission_entry(key, transaction, served)
        variant.cached ? PermissionForge::ConditionalSets.variant_hash(entry, variant) : entry
      end

      # Writes the index entry by which the enumerated cache:clear finds the
      # variants of the base at `key` (Cache::VariantRemoval; erasure removes
      # every slot without it) — after the variant's rebuild read the stamp,
      # before the variant is written. A variant whose rebuild read the stamp
      # before an invalidation is either verified before it, its index entry
      # already there for the removal that follows the invalidation, or
      # discarded by its verification. A variant whose index entry was not
      # written is not stored: the clear would not find it. The entry
      # outlives every variant written after it
      # (ConditionalSets::INDEX_TTL_MARGIN).
      #
      # @return [Boolean] whether the store took the index entry
      def pf_variant_indexed?(key)
        sets = PermissionForge::ConditionalSets
        ttl = PermissionForge.configuration.cache_ttl
        PermissionForge.cache.write(sets.index_key(key), sets::INDEX, ttl: ttl && (ttl + sets::INDEX_TTL_MARGIN)) ? true : false
      end

      # Everything a build reads is read outside ActiveRecord's query cache.
      # Inside a request the cache would answer the queries of a repeated
      # build — or of a second rebuild later in the request — with the rows
      # the first one read.
      #
      # The base entry (variant nil) is built from the unconditional sets and
      # carries the conditional ones, and when the soonest assignment ends
      # (EXPIRY_KEY); a variant from the unconditional sets plus those of the
      # variant, and — when it is stored — carries what it was built for
      # (ConditionalSets.variant_entry). The TTL is that of all the user's
      # sets either way.
      #
      # @return [Array(Hash, Integer)] the entry and its TTL (nil for none)
      def pf_build_permission_entry(variant)
        PermissionForge::PermissionSet.uncached do
          permission_sets = pf_active_non_expired_permission_sets
          conditional = PermissionForge::ConditionalSets.of(permission_sets)

          permission_data = PermissionForge::Services::PermissionHashBuilder.call(
            user: self,
            permission_sets: PermissionForge::ConditionalSets.build_sets(permission_sets, variant)
          )

          profile = PermissionForge.configuration.profile_builder.call(self)

          soonest = pf_soonest_assignment_expiry
          entry = { profile: profile, preferences: {}, permissions: permission_data }
          if variant.nil?
            pf_carry_in_base_entry(entry, conditional, soonest)
          elsif variant.cached
            entry = PermissionForge::ConditionalSets.variant_entry(entry, variant)
          end
          [entry, pf_permission_cache_ttl(permission_sets, soonest)]
        end
      end

      # What the base entry carries beside the hash: the user's conditional
      # sets (ConditionalSets::ENTRY_KEY) and when the soonest assignment
      # ends (EXPIRY_KEY), each only when there is one.
      def pf_carry_in_base_entry(entry, conditional, soonest)
        entry[PermissionForge::ConditionalSets::ENTRY_KEY] = conditional.dump if conditional
        entry[EXPIRY_KEY] = soonest.to_i if soonest
      end

      # The request context the activation conditions are evaluated against
      # (config.request_context_resolver), resolved on every read of a user
      # with conditional sets. A resolver that reads the permissions of the
      # user it resolves for — a masked attribute of Current.user, a can_*?
      # check — would be answered the hash being selected: one from another
      # context, or {} (which switches row-level rules off). Neither is safe,
      # so it raises instead — on every read of such a user.
      #
      # The context is a Hash; anything else the resolver returns (a Struct,
      # an object with #to_h) is taken as its #to_h.
      #
      # @return [Hash]
      # @raise [PermissionForge::ConfigurationError] when the resolver reads
      #   this user's permissions
      def pf_resolve_request_context(key)
        building = PermissionForge::ExecutionState.fetch(BUILDING_KEY) { {} }
        build = building[key]
        if build&.[](:resolving)
          raise PermissionForge::ConfigurationError,
                "config.request_context_resolver read the permissions of the user it resolves the context for (#{key}): " \
                'a resolver must not read permissions'
        end

        own = build.nil?
        build = building[key] = {} if own
        build[:resolving] = true
        begin
          pf_context_hash(PermissionForge.configuration.request_context_resolver.call)
        ensure
          own ? building.delete(key) : build.delete(:resolving)
        end
      end

      def pf_context_hash(context)
        context.is_a?(Hash) ? context : context.to_h
      end
    end
  end
end
