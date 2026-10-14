module PermissionForge
  module Concerns
    # Invalidates the cached permission hash of every user affected by a change
    # to the including permission model. The rebuild happens lazily on each
    # user's next permissions_hash read (read-through in PermissionCacheAccessor),
    # so activation conditions are evaluated in the affected user's own request
    # context — not the context of whoever edited the permission records.
    #
    # Runs after commit through InvalidatesInBatch: the records written in one
    # transaction invalidate each affected user once (per tenant), not once per
    # record.
    #
    # @api private
    module PermissionsRegenerator
      extend ActiveSupport::Concern
      include InvalidatesInBatch

      # NOTE: The including model must define a private method `users_on_permission_set`
      # that returns a collection of PermissionForge::PermissionSetUser records
      # (or `user_ids_on_permission_set`, the ids of their users).

      private

      def invalidate_committed_caches
        super
        invalidate_permissions_for_users
      end

      def invalidate_permissions_for_users
        invalidate_assigned_users(user_ids_on_permission_set, invalidation_batch, permission_record_tenant_id)
      end

      # The user ids of users_on_permission_set — plucked from a relation,
      # without loading a row.
      def user_ids_on_permission_set
        holders = users_on_permission_set
        return holders.distinct.pluck(:user_id) if holders.is_a?(ActiveRecord::Relation)

        holders.filter_map(&:user_id).uniq
      end
    end
  end
end
