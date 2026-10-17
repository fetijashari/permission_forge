# The "public index" of docs/controller-actions.md#callback-order, served for
# the browser flows: opened with allow_unauthenticated_access, the session
# resumed ahead of the guard, checked as the Customer resource.
class PublicCustomersController < ApplicationController
  permission_forge_actions resource: 'Customer'
  allow_unauthenticated_access only: :index
  prepend_before_action :resume_session, only: :index # Current.user for a signed-in visitor

  def index
    @customers = Customer.permission_scoped
  end
end
