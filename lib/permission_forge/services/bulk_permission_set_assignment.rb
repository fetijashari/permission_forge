module PermissionForge
  module Services
    # Assigns or revokes a permission set for multiple users in a single
    # transaction. Each assignment created or destroyed invalidates its
    # user's cached permissions after the commit (PermissionSetUser's own
    # after_commit), once per user; each user's hash is rebuilt read-through
    # on their next request, in their own context.
    #
    # @example Bulk assign
    #   result = BulkPermissionSetAssignment.call(
    #     permission_set: ps, user_ids: [1, 2, 3], action: :assign
    #   )
    #   # => { assigned: 3, revoked: 0, invalidated: 3 }
    #
    # `invalidated` counts the users assigned or revoked whose invalidation
    # the cache store confirmed. Fewer means the store failed for the rest
    # (reported through `config.on_cache_failure`): their cached permissions
    # may live until cache_ttl. A user who already held the set (assign) or
    # never did (revoke) changed nothing and is not invalidated. Inside a
    # transaction of the caller the invalidations happen at its commit, after
    # this returns: `invalidated` is then nil (not known).
    #
    # Every row is created or destroyed through its callbacks, so each person
    # gets an assignment.granted / assignment.revoked audit event, all with
    # one correlation id (the transaction's). The reason (a ticket, free
    # text) comes from the surrounding Audit::Context.
    #
    # @api public
    class BulkPermissionSetAssignment
      ACTION_STRATEGIES = {
        assign: :assign_users,
        revoke: :revoke_users
      }.freeze

      VALID_ACTIONS = ACTION_STRATEGIES.keys.freeze

      # Assigns or revokes a Permission Set for many users in one transaction.
      # @return [Hash] `{ assigned:, revoked:, invalidated: }`
      def self.call(...) = new(...).call

      # @raise [ArgumentError] unless `action` is one of VALID_ACTIONS
      def self.validate_action!(action)
        action = action.presence&.to_sym
        return action if VALID_ACTIONS.include?(action)

        raise ArgumentError, "Invalid action: #{action}. Must be one of: #{VALID_ACTIONS.join(', ')}"
      end

      def initialize(permission_set:, user_ids:, action:, created_by: nil, expires_at: nil)
        @permission_set = permission_set
        # Host keys as given: `to_i` would turn a UUID into its leading digits
        # and assign whoever owns that number.
        @user_ids = Array(user_ids).compact_blank.map(&:to_s).uniq
        @action = action&.to_sym
        @created_by = created_by
        @expires_at = expires_at
        @assigned_count = 0
        @revoked_count = 0
        @changed_user_ids = []
      end

      # @return [Hash] `{ assigned:, revoked:, invalidated: }`
      def call
        validate_action!

        deferred = PermissionForge::OpenTransaction.current
        failures = PermissionForge::Cache::Failure.collect do
          ActiveRecord::Base.transaction { send(ACTION_STRATEGIES.fetch(@action)) }
        end

        # what the store confirmed (Cache::Failure) — not what a host's override of invalidate_permissions returns
        { assigned: @assigned_count, revoked: @revoked_count, invalidated: deferred ? nil : failures.confirmed(@changed_user_ids).size }
      end

      private

      def validate_action!
        self.class.validate_action!(@action)
      end

      def assign_users
        users = PermissionForge.configuration.user_model.where(id: @user_ids)
        existing_user_ids = @permission_set.permission_set_users.where(user_id: @user_ids).pluck(:user_id)

        users.each do |user|
          next if existing_user_ids.include?(user.id)

          @permission_set.permission_set_users.create!(
            user: user,
            expires_at: @expires_at,
            created_by_id: @created_by&.id,
            updated_by_id: @created_by&.id
          )
          @assigned_count += 1
          @changed_user_ids << user.id
        end
      end

      # Through callbacks, as destroy_all; a row a callback refuses to
      # destroy (destroy answers false) is neither revoked nor counted.
      def revoke_users
        revoked = @permission_set.permission_set_users.where(user_id: @user_ids).to_a.select(&:destroy)
        @revoked_count = revoked.size
        @changed_user_ids = revoked.map(&:user_id).uniq
      end
    end
  end
end
