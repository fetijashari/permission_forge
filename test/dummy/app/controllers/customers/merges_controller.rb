module Customers
  # A nested controller whose REST action means a custom action on Customer:
  # `create` is checked as the `merge` action, not as create_access.
  class MergesController < ApplicationController
    include PermissionForge::Concerns::ControllerActionGuard

    permission_forge_actions resource: 'Customer', actions: { create: :merge }

    def create = head(:ok)
  end
end
