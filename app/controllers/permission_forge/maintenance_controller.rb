module PermissionForge
  # Housekeeping triggered from the home page.
  #
  # @api private
  class MaintenanceController < ApplicationController
    # Removes expired assignments (the dry run is shown on Home first).
    def cleanup
      result = PermissionForge::Services::ExpiredAssignmentCleaner.call
      redirect_to permission_forge.root_path,
                  notice: t('permission_forge.flash.maintenance.cleaned', count: result[:removed])
    end
  end
end
