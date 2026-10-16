# As `bin/rails generate authentication` leaves it, plus the guard the
# getting-started guide puts here. docs/row-level-rules.md replaces this file
# with the documented handler (a `file=` block).
class ApplicationController < ActionController::Base
  include Authentication
  include PermissionForge::Concerns::ControllerActionGuard
end
