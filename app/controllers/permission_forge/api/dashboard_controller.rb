# frozen_string_literal: true

module PermissionForge
  module Api
    class DashboardController < BaseController
      before_action :require_admin!, only: :show

      def show
        render json: {
          data: {
            permission_sets_count: PermissionForge::PermissionSet.count,
            active_sets_count: PermissionForge::PermissionSet.active.count,
            resources_count: PermissionForge::Resource.count,
            rules_count: PermissionForge::PermissionSetRule.count,
            groups_count: PermissionForge::PermissionSetGroup.count,
            users_count: PermissionForge::PermissionSetUser.select(:user_id).distinct.count
          }
        }, status: :ok
      end

      private

      def require_admin!
        return unless PermissionForge.configuration.api_stats_require_admin

        head :forbidden unless @admin
      end
    end
  end
end
