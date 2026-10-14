module PermissionForge
  # The HTML admin's gate in front of the audit log: the log page, one
  # event, the exports, and the audit tabs of a person and a Permission Set.
  # Audit::LogAccess decides (config.audit_log_authorization); a refusal is
  # recorded once per request (admin.auth_failed, reason
  # audit_log_not_authorized) and answered with a 403 — a page that says so,
  # or nothing for a file. A refused request is never recorded as viewed or
  # exported (Audit::AuditedViews records 2xx responses only).
  #
  # @api private
  module AuditLogGate
    REFUSAL_REASON = 'audit_log_not_authorized'.freeze

    private

    # @return [Boolean] whether this request may read the audit log
    def pf_audit_log_allowed?
      return @pf_audit_log_allowed if defined?(@pf_audit_log_allowed)

      @pf_audit_log_allowed = PermissionForge::Audit::LogAccess.allowed?(self)
      pf_audit_refused('admin.auth_failed', data: { 'reason' => REFUSAL_REASON }) unless @pf_audit_log_allowed
      @pf_audit_log_allowed
    end

    # before_action: the refusal, unless the log may be read.
    def pf_require_audit_log!
      pf_render_audit_refusal unless pf_audit_log_allowed?
    end

    # The audit tab of a page (people#show, permission_sets#show) and its
    # CSV are the audit log too; the other tabs need no permission.
    def pf_audit_tab_allowed?
      return true unless @tab == 'audit' || request.format.csv?

      pf_audit_log_allowed?
    end

    # Refused on a page with tabs: the page renders with the refusal on its
    # audit tab (403); a file is not sent.
    def pf_refuse_audit_tab
      return head(:forbidden) unless request.format.html?

      @audit_refused = true
      render :show, status: :forbidden
    end

    def pf_render_audit_refusal
      if request.format.html?
        render 'permission_forge/shared/audit_refused', status: :forbidden
      else
        head :forbidden
      end
    end
  end
end
