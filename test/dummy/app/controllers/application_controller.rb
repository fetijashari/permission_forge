class ApplicationController < ActionController::Base
  # The action guard only raises; answering is the host app's job.
  rescue_from PermissionForge::ActionNotAuthorizedError do
    head :forbidden
  end
end
