module PermissionForge
  module Services
    # Aggregates dashboard statistics from permission models.
    # Extracted from DashboardController for SRP.
    #
    # @api private
    class DashboardStats
      def self.call
        {}.merge(permission_set_stats).merge(model_counts).merge(recent_records)
      end

      class << self
        private

        def permission_set_stats
          {
            permission_sets_count: PermissionForge::PermissionSet.count,
            active_sets_count: PermissionForge::PermissionSet.active.count,
            muting_sets_count: PermissionForge::PermissionSet.muting.count,
            conditional_sets_count: PermissionForge::PermissionSet.conditional.count,
            expired_assignments_count: PermissionForge::PermissionSetUser.expired.count
          }
        end

        def model_counts
          {
            resources_count: PermissionForge::Resource.count,
            rules_count: PermissionForge::PermissionSetRule.count,
            groups_count: PermissionForge::PermissionSetGroup.count,
            users_count: PermissionForge::PermissionSetUser.select(:user_id).distinct.count
          }
        end

        def recent_records
          {
            recent_permission_sets: PermissionForge::PermissionSet.order(created_at: :desc).limit(5),
            recent_resources: PermissionForge::Resource.order(created_at: :desc).limit(5)
          }
        end
      end
    end
  end
end
