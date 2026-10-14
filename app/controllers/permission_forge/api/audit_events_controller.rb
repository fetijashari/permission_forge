# frozen_string_literal: true

module PermissionForge
  module Api
    # Read-only view of the audit log. Gated by api_enabled and api_auth (the
    # base controller) and then by config.audit_log_authorization
    # (Audit::LogAccess). Rows are tenant-scoped by the model.
    class AuditEventsController < BaseController
      before_action :authorize_audit_log!

      rescue_from PermissionForge::Audit::EventQuery::Invalid do |error|
        render json: { error: { status: 422, messages: error.errors } }, status: :unprocessable_entity
      end

      def index
        render_collection(PermissionForge::Audit::EventQuery.call(params), serializer_for(:audit_event))
      end

      def show
        render_record(find_record(PermissionForge::AuditEvent), serializer_for(:audit_event))
      end

      private

      def authorize_audit_log!
        return if PermissionForge::Audit::LogAccess.allowed?(self)

        pf_audit_refused('api.auth_failed', data: { 'reason' => 'audit_log_not_authorized' })
        render_not_authorized
      end
    end
  end
end
