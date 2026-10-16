Rails.application.routes.draw do
  mount PermissionForge::Engine, at: "/permissions"
end
