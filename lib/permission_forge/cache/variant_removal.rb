# frozen_string_literal: true

module PermissionForge
  module Cache
    # Removes the per-context variants of users with conditional permission
    # sets, where the personal data they hold (the profile) must go now:
    # Services::DataSubjectErasure and the enumerated
    # Services::PermissionCacheClearer. An invalidation leaves them to their
    # TTL: no read can reach them once the base entry that carries their
    # token is gone (ConditionalSets).
    #
    # For the clear (indexed_only, many users) the users' index entries are
    # read (UserKeys.variant_removals, one call per SLICE users), and for each
    # one found the index entry and every slot of its base entry go. For an
    # erasure (one person) nothing is read: the index entry and every slot of
    # each of the person's base entries go — a read that fails silently, or
    # an index entry the store evicted, cannot leave a variant behind. Either
    # way the keys are removed the way an invalidation removes them
    # (BulkInvalidation: a fresh stamp first, every answer checked, retries,
    # what fails reported through Cache::Failure and owed).
    #
    # Callers run it after the users' invalidation. A variant whose rebuild
    # read the stamp before that invalidation was then either verified
    # before it — its index entry, written first, is found here — or is
    # discarded by its verification. A rebuild still in flight that reads the
    # stamp after the removal's and writes after it leaves a variant built
    # from the rows as they are then (its profile from that request's user
    # instance, which may predate the change): unreachable, gone with its TTL.
    #
    # @api private
    class VariantRemoval
      def self.call(...) = new(...).call

      # @param user_ids [Array]
      # @param tenant_id [Object, nil] the tenant whose base keys to include
      #   besides the ambient and the tenant-agnostic ones (UserKeys.base_keys)
      # @param indexed_only [Boolean] only the base entries whose index entry
      #   is found (false: every base entry, nothing read)
      # @param named [Hash] ambient_key: — the key a single user instance
      #   names (#permission_cache_key)
      def initialize(user_ids:, tenant_id: nil, indexed_only: true, **named)
        @user_ids = user_ids
        @tenant_id = tenant_id
        @named = named.merge(indexed_only: indexed_only)
      end

      # @return [Array] the ids whose removal the store did not confirm
      def call
        @user_ids.each_slice(HolderInvalidation::SLICE).flat_map do |slice|
          BulkInvalidation.unconfirmed(UserKeys.variant_removals(slice, tenant_id: @tenant_id, **@named))
        end
      end
    end
  end
end
