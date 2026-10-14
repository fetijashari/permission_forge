# Fixture for the audit integration suite (test/permission_forge/audit_integration):
# a plain host controller that reads and writes Customer through the gem's
# runtime guards — record rules on find_by, auto-scoping, field masking on
# as_json and parameter filtering. Not guarded and named after no model, so
# controller-action discovery leaves it out.
class PfAuditProbesController < ApplicationController
  rescue_from PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError do
    head :forbidden
  end

  # Two auto-scoped queries in one request.
  def index
    first = Customer.where(domain: 'example.com').to_a
    second = Customer.where(domain: 'example.com').count
    render json: { listed: first.size, counted: second }
  end

  # find_by under the record rules; the record serialized through its masks.
  def show
    render json: Customer.find_by!(id: params[:id]).as_json
  end

  # The write path: only the attributes the user may edit are kept.
  def update
    permitted = PermissionForge::Services::PermitsAttributes.call(resource: Customer, permitted_params: params.require(:customer).permit!.to_h)
    render json: permitted
  end
end
