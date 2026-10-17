# Fixture for masking with nobody signed in inside a web request
# (masked_attributes_nil_user_strategy :hide_in_requests and :bypass): a
# public host page that reads Customer before any sign-in — in a
# before_action, as a tenant or subdomain lookup would — and in the action.
# Not guarded and named after no model, so controller-action discovery
# leaves it out.
class PfPublicPagesController < ApplicationController
  before_action :look_up_before_sign_in

  def show
    customer = Customer.find_by!(id: params[:id])
    render json: { before_action: @looked_up, email: customer.email, name: customer.name, as_json: customer.as_json,
                   attributes: customer.attributes.slice('id', 'name', 'email') }
  end

  private

  def look_up_before_sign_in
    @looked_up = Customer.find_by(id: params[:id])&.email
  end
end
