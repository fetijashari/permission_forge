# frozen_string_literal: true

module PermissionForge
  module Cache
    # Invalidates the cached hashes of the holders of a changed permission
    # record by user id, in slices of SLICE users: the same stamps and keys
    # as User#invalidate_permissions (Cache::UserKeys), made through
    # BulkInvalidation — one multi-key write for the stamps and one for the
    # keys per slice — without loading a single user. A change to a set with
    # 10,000 holders cost 30,000 store calls and 20,000 loaded records in the
    # saving request before.
    #
    # Only where nothing but those store calls would happen for a user
    # (.by_id?). Otherwise the holders are loaded and invalidated one by one
    # through the public User#invalidate_permissions, as before
    # (Concerns::InvalidatesInBatch):
    #   - the user model overrides invalidate_permissions, or the key or
    #     stamp it is built from (PermissionCacheAccessor): the host's code
    #     has to run;
    #   - somebody listens for permissions.invalidated (or stores it): each
    #     event carries its user;
    #   - the hashes are withheld in an open transaction that reads from a
    #     snapshot (OpenTransaction.withholding): each invalidation is then
    #     settled after the commit by the user's own instance.
    #
    # The processes' memos are retired as invalidate_permissions retires
    # them: the cache version is bumped once per slice. Nothing is read: the
    # per-context variants of a user with conditional sets are left to their
    # TTL, unreachable once the base entry is gone (Cache::UserKeys).
    #
    # @api private
    class HolderInvalidation
      SLICE = 500
      EVENT = 'permissions.invalidated'

      # The methods of PermissionCacheAccessor whose work this does in bulk.
      OWN_METHODS = %i[invalidate_permissions permission_cache_key pf_invalidation_stamp_key].freeze

      class << self
        def call(...) = new(...).call

        # Whether the holders can be invalidated by id, here and now.
        #
        # @param model [Class] the host's user model
        # @return [Boolean]
        def by_id?(model)
          own_methods?(model) && !PermissionForge::Audit.instrument?(EVENT) && !PermissionForge::OpenTransaction.withholding
        end

        private

        # The model and its subclasses (an STI `Admin < User` that overrides
        # them would be loaded as an Admin by the per-user path). A subclass
        # that is not loaded yet (development) is not seen.
        def own_methods?(model)
          [model, *model.descendants].all? do |klass|
            OWN_METHODS.all? do |name|
              (klass.method_defined?(name) || klass.private_method_defined?(name)) &&
                klass.instance_method(name).owner == PermissionForge::Concerns::PermissionCacheAccessor
            end
          end
        end
      end

      # @param user_ids [Array] the holders' ids (no duplicates)
      # @param tenant_id [Object, nil] the changed record's tenant
      def initialize(user_ids:, tenant_id:)
        @user_ids = user_ids
        @tenant_id = tenant_id
      end

      # @return [Array] the ids whose invalidation the store did not confirm
      #   (each reported through Cache::Failure, and owed)
      def call
        @user_ids.each_slice(SLICE).flat_map do |slice|
          # a slice whose invalidation raised is owed and reported user by user, and the next slices still get theirs
          BulkInvalidation.unconfirmed(UserKeys.invalidations(slice, tenant_id: @tenant_id))
        ensure
          # after the invalidation, whatever became of it, as invalidate_permissions does
          PermissionForge.bump_permissions_cache_version!
        end
      end
    end
  end
end
