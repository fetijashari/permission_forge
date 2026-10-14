# Fixture for controller-action discovery and the action guard: REST actions
# plus two custom ones. Guarded with no declaration, so every action maps to
# the Customer resource by convention.
class CustomersController < ApplicationController
  include PermissionForge::Concerns::ControllerActionGuard

  def index = head(:ok)
  def show = head(:ok)
  def export = head(:ok)
  def archive = head(:ok)
end
