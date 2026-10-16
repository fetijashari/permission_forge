module PermissionForge
  # Housekeeping triggered from the home page.
  #
  # @api private
  class MaintenanceController < ApplicationController
    include PermissionForge::CacheConfirmation

    # Removes expired assignments (the dry run is shown on Home first). The
    # flash says what the cache store confirmed for the affected people, and
    # when the store lives in this process only (CacheConfirmation).
    def cleanup
      result = PermissionForge::Services::ExpiredAssignmentCleaner.call
      redirect_to permission_forge.root_path,
                  **cache_flash(result[:cache], { notice: :cleaned, alert: :cleaned_cache_kept }, count: result[:removed])
    end
  end
end
