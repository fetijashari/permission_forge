# frozen_string_literal: true

module PermissionForge
  module Api
    # Read-only view of the audit log. Gated by api_enabled and api_auth (the
    # base controller) and then by config.audit_log_authorization
    # (Audit::LogAccess). Rows are tenant-scoped by the model.
    class AuditEventsController < BaseController
      before_action :authorize_audit_log!
      before_action :require_audit_store!

      rescue_from PermissionForge::Audit::EventQuery::Invalid do |error|
        render_unprocessable(error.errors)
      end

      def index
        render_collection(PermissionForge::Audit::EventQuery.call(params), serializer_for(:audit_event))
      end

      def show
        render_record(find_record(PermissionForge::AuditEvent), serializer_for(:audit_event))
      end

      private

      # 503 in the usual error envelope while the audit table does not exist.
      def require_audit_store!
        return if PermissionForge::Admin::AuditLog.table?

        key = PermissionForge::Admin::AuditLog.recording_problem == :off ? 'audit_unavailable_off' : 'audit_unavailable_missing'
        render_unavailable(I18n.t("permission_forge.api.errors.#{key}"))
      end

      def authorize_audit_log!
        return if PermissionForge::Audit::LogAccess.allowed?(self)

        pf_audit_refused('api.auth_failed', data: { 'reason' => 'audit_log_not_authorized' })
        render_not_authorized
      end
    end
  end
end
