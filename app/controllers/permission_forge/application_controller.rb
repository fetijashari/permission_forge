module PermissionForge
  # Base class of the admin screens. Inherits from `config.base_controller_class`, so the host's
  # authentication and layout apply.
  #
  # @api public
  class ApplicationController < PermissionForge.configuration.base_controller_class.constantize
    # Include standard ActionController modules when inheriting from a base
    # that may not have them (e.g. ActionController::Base vs ApplicationController)
    ActionController::Base::MODULES.each do |mod|
      include mod unless self < mod
    end

    include PermissionForge::ForgeryProtection

    protect_from_forgery with: :exception, **pf_forgery_strategy
    # Several admin forms submit to more than one action via `formaction`
    # buttons (rule builder refresh, bulk "Check names", "Apply
    # recommendation"). Per-form tokens are bound to the form's own action, so
    # those submissions would fail verification; the session-wide (masked)
    # token still protects every request.
    self.per_form_csrf_tokens = false

    layout :pf_layout

    include PermissionForge::BasicAuthentication
    include PermissionForge::TenantRequired
    include PermissionForge::ParamShapes
    include PermissionForge::HtmlFormat

    THEMES = %w[auto light dark].freeze
    FRAGMENT_HEADER = 'X-PF-Fragment'.freeze
    AUDIT_SOURCE = 'admin_ui'.freeze

    before_action :set_locale
    before_action :pf_require_tenant
    around_action :pf_without_permission_scope
    # After authentication (a refused sign-in records its own event) and
    # inside the scope suspension (an actor resolver may query).
    around_action :pf_audit_request

    # The uniqueness race (two requests passed the uniqueness validation
    # together; the unique index refused this one's INSERT): back to the
    # page the form was on (the admin's home without a Referer, never
    # another host) with the validation's message for the index the error
    # names (UniqueConflict), or the generic one. 303: the browser follows
    # with a GET whatever the form's method was. Through 0.14.1 a 500.
    rescue_from ActiveRecord::RecordNotUnique do |error|
      detail = PermissionForge::UniqueConflict.sentence(error)
      alert = detail ? t('permission_forge.flash.record_not_unique_detail', detail: detail) : t('permission_forge.flash.record_not_unique')
      redirect_back_or_to permission_forge.root_path, alert: alert, allow_other_host: false, status: :see_other
    end

    # A NOT NULL column no validation foresaw (ValidatesRequiredColumns
    # covers the gem's own columns): back to the page like the uniqueness
    # race, never a 500.
    rescue_from ActiveRecord::NotNullViolation do
      redirect_back_or_to permission_forge.root_path, alert: t('permission_forge.flash.not_null'), allow_other_host: false,
                                                      status: :see_other
    end

    helper PermissionForge::ApplicationHelper unless self < PermissionForge::ApplicationHelper
    helper_method :pf_fragment?, :pf_theme, :pf_help_visible?, :pf_current_admin,
                  :pf_attention, :pf_settings_catalog, :pf_back_or

    private

    # Memoized per request: drives the Home badge and the home page.
    def pf_attention
      @pf_attention ||= PermissionForge::Admin::AttentionItems.new
    end

    def pf_settings_catalog
      @pf_settings_catalog ||= PermissionForge::Admin::SettingsCatalog.new(attention: pf_attention)
    end

    def set_locale
      session[:permission_forge_locale] = params[:locale] if params[:locale].present? && available_locale?(params[:locale])

      I18n.locale = session[:permission_forge_locale] || I18n.default_locale
    end

    def available_locale?(locale)
      allowed = PermissionForge.configuration.available_locales || PermissionForge::BUNDLED_LOCALES
      Array(allowed).map(&:to_s).include?(locale.to_s)
    end

    def default_url_options
      {}
    end

    # The admin manages permissions for everyone, so it must see every record:
    # suspend Level 1 auto-scoping / Level 2 detection for the request.
    def pf_without_permission_scope(&)
      PermissionForge.without_permission_scope(&)
    end

    # Who acts, from where, which request and why — for every audit event of
    # the request; one correlation id for a request that changes something;
    # the read-only pages of Audit::AuditedViews recorded after success.
    # Nothing of it outlives the request (Audit::RequestContext).
    def pf_audit_request(&)
      PermissionForge::Audit::RequestContext.wrap(self, source: AUDIT_SOURCE, &)
    end

    # Records a refused request (admin.auth_failed, admin.lock_refused …) so
    # that no rollback takes it along. `data` gets method, path and endpoint.
    #
    #   pf_audit_refused('admin.auth_failed', data: { 'reason' => 'assignment_not_authorized' }, permission_set: set)
    def pf_audit_refused(event, **payload)
      PermissionForge::Audit::RequestContext.refused(self, event, source: AUDIT_SOURCE, **payload)
    end

    # Requests from the progressive-enhancement script that load a page into
    # a drawer/dialog get the bare content, without the sidebar layout.
    def pf_fragment?
      request.headers[FRAGMENT_HEADER].present?
    end

    def pf_layout
      pf_fragment? ? 'permission_forge/fragment' : 'permission_forge/application'
    end

    def pf_theme
      theme = cookies[:pf_theme].to_s
      THEMES.include?(theme) ? theme : 'auto'
    end

    def pf_dismissed_help
      cookies[:pf_help].to_s.split(',').grep(/\A[a-z_]+\z/)
    end

    def pf_help_visible?(key)
      !pf_dismissed_help.include?(key.to_s)
    end

    # Cookies are scoped to the engine's mount path so they never collide with
    # (or leak into) the host app's own cookies, and are Secure whenever the
    # admin is served over HTTPS.
    def pf_cookie(name, value)
      cookies[name] = { value: value, path: pf_mount_path, httponly: true, same_site: :lax,
                        secure: request.ssl?, expires: 1.year.from_now }
    end

    def pf_mount_path
      request.script_name.presence || '/'
    end

    def pf_current_admin
      return @pf_current_admin if defined?(@pf_current_admin)

      @pf_current_admin = begin
        PermissionForge.current_user
      rescue StandardError
        nil
      end
    end

    # Redirect with a toast. `undo:` is { path:, method:, params: } for a
    # one-click reversal rendered inside the toast.
    # Messages: notice:, alert:.
    def pf_redirect(path, undo: nil, **messages)
      flash[:pf_undo] = undo if undo
      redirect_to path, **messages.slice(:notice, :alert)
    end

    def pf_back_or(default)
      target = params[:return_to].to_s
      pf_local_path?(target) ? target : default
    end

    # Same-origin path ("/x"), never protocol-relative ("//host"), and
    # nothing a browser could read as another host: no backslash ("/\\host")
    # and no control character (a tab or newline inside "//").
    def pf_local_path?(path)
      path.start_with?('/') && !path.start_with?('//') && !path.match?(/[\\[:cntrl:]]/)
    end

    # Expiry preset + custom date posted by the assign forms.
    def pf_load_expiry
      @expiry = PermissionForge::Admin::ExpiryPresets::KEYS.include?(params[:expiry]) ? params[:expiry] : 'never'
      @custom_date = params[:custom_date].to_s
    end

    # Sets @expires_at from the chosen preset; returns the translated error
    # for an invalid custom date, else nil.
    def pf_resolve_expiry
      @expires_at = PermissionForge::Admin::ExpiryPresets.expires_at_for(@expiry, custom: @custom_date)
      nil
    rescue PermissionForge::Admin::ExpiryPresets::InvalidDate => e
      t("permission_forge.errors.admin.expiry_#{e.message}")
    end

    def pf_people_count(permission_set)
      permission_set.permission_set_users.active_assignments.count
    end

    def pf_not_found
      raise ActionController::RoutingError, 'Not Found'
    end

    # Redirects with an alert when the record (or any of `records`), or what
    # it belongs to (Admin::EditableLock: its Resource, Permission Set, the
    # Group of a membership), is locked, and records the refusal
    # (admin.lock_refused, naming the locked record); returns whether it was.
    def pf_reject_locked!(records, path, alert: t('permission_forge.flash.not_editable')) # rubocop:disable Naming/PredicateMethod -- redirects; the answer says whether it did
      locked = PermissionForge::Admin::EditableLock.locked_record(records)
      if locked
        pf_audit_refused('admin.lock_refused', record: locked)
        redirect_to path, alert: alert
      end
      locked ? true : false
    end
  end
end
