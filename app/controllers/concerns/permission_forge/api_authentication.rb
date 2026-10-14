# frozen_string_literal: true

module PermissionForge
  # @api private
  module ApiAuthentication
    extend ActiveSupport::Concern

    included do
      before_action :verify_api_enabled!
      before_action :authenticate_api_request!
    end

    private

    def verify_api_enabled!
      return if PermissionForge.configuration.api_enabled

      head :not_found
    end

    # A refused request records api.auth_failed: who the host knows (the
    # audit actor resolver, the signed-in user), else unknown.
    def authenticate_api_request!
      auth_check = PermissionForge.configuration.api_auth
      if auth_check.nil?
        audit_api_auth_failure('api_auth_not_configured', 401)
        return head(:unauthorized)
      end
      return if auth_check.call(self)

      audit_api_auth_failure('api_auth_denied', 403)
      render json: { error: { status: 403, messages: I18n.t('permission_forge.api.errors.forbidden') } }, status: :forbidden
    end

    def audit_api_auth_failure(reason, status)
      PermissionForge::Audit::RequestContext.refused(self, 'api.auth_failed', source: 'api',
                                                                              data: { 'reason' => reason, 'status' => status })
    end
  end
end
