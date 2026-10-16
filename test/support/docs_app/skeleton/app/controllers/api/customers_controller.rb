# A JSON client of the same data, behind the documented Api::BaseController.
# Nobody is signed in through the API: the session cookie is resumed by hand,
# as an app that shares its sign-in with its JSON clients would.
class Api::CustomersController < Api::BaseController
  include ActionController::Cookies
  include PermissionForge::Concerns::ControllerActionGuard
  prepend_before_action :resume_session

  def index
    render json: Customer.permission_scoped.map { |customer| customer.as_json(only: %i[id name email phone status notes owner_id]) }
  end

  def show
    render json: Customer.find_by!(id: params[:id]).as_json(only: %i[id name email phone status notes owner_id])
  end

  private
    def resume_session
      Current.session ||= Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end
end
