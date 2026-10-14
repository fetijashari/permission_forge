module PermissionForge
  # The admin screens and the admin API serve one tenant at a time. With
  # tenancy on (config.tenant_model) a request that reaches them with no
  # current tenant is refused — acts_as_tenant scopes nothing without one, so
  # it would read and change every tenant's Permission Sets, assignments and
  # audit log — unless config.admin_tenantless_access = :allow. The refusal
  # is recorded through the including controller's pf_audit_refused
  # (admin.auth_failed / api.auth_failed, reason tenant_missing) and answered
  # with a 403: JSON from the API, plain text from the admin screens (their
  # layout's navigation and counts would read across tenants).
  #
  # The including controller registers `before_action :pf_require_tenant`
  # after authentication and its locale: an unauthenticated request still
  # gets its 401, the refusal is in the request's language, and a host base
  # controller's own callbacks (which set the tenant) have run.
  #
  # @api public
  module TenantRequired
    REFUSAL_REASON = 'tenant_missing'.freeze
    API_SOURCE = 'api'.freeze

    private

    def pf_require_tenant
      return unless pf_tenant_missing?

      api = self.class::AUDIT_SOURCE == API_SOURCE
      pf_audit_refused(api ? 'api.auth_failed' : 'admin.auth_failed', data: { 'reason' => REFUSAL_REASON })
      if api
        render json: { error: { status: 403, messages: I18n.t('permission_forge.api.errors.tenant_required') } },
               status: :forbidden
      else
        render plain: I18n.t('permission_forge.errors.tenant_required'), status: :forbidden
      end
    end

    def pf_tenant_missing?
      config = PermissionForge.configuration
      config.tenant_enabled? && !config.admin_tenantless_access_allowed? && PermissionForge.ambient_tenant.nil?
    end
  end
end
