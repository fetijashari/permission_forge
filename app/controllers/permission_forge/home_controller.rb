module PermissionForge
  # "Needs attention": what the owner should look at, plus quick lookups.
  #
  # @api private
  class HomeController < ApplicationController
    PRIVACY_PREVIEW = 5

    def index
      @attention = pf_attention
      @first_run = !PermissionForge::PermissionSet.exists?
      @show_all_privacy = params[:privacy] == 'all'
      @cleanup_preview = params[:cleanup].present?
      @people_with_access = live_assignments.distinct.count(:user_id)
      @active_sets = PermissionForge::PermissionSet.active.count
    end

    private

    def live_assignments
      PermissionForge::PermissionSetUser.active_assignments
                                        .where(permission_set_id: PermissionForge::PermissionSet.active.select(:id))
    end
  end
end
