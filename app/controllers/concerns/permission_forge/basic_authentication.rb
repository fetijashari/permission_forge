module PermissionForge
  # HTTP Basic authentication for the admin screens, driven by `config.http_basic_auth_*`;
  # the engine's controllers include it.
  #
  # @api public
  module BasicAuthentication
    extend ActiveSupport::Concern

    # A username is stored as the actor label of an event: a varchar(255).
    AUDIT_USERNAME_LIMIT = 255

    included do
      before_action :authenticate_by_http_basic
    end

    private

    def authenticate_by_http_basic
      return unless http_basic_auth_enabled?

      unless http_basic_auth_configured?
        audit_http_basic_failure('basic_auth_not_configured')
        return head(:unauthorized)
      end

      authenticate_or_request_with_http_basic('PermissionForge') do |given_user, given_password|
        verified = http_basic_credentials_match?(given_user, given_password)
        verified ? remember_http_basic_user : audit_http_basic_failure('invalid_credentials')
        verified
      end
    end

    def http_basic_credentials_match?(given_user, given_password)
      ActiveSupport::SecurityUtils.secure_compare(given_user, http_basic_auth_credentials[:user].to_s) &
        ActiveSupport::SecurityUtils.secure_compare(given_password, http_basic_auth_credentials[:password].to_s)
    end

    # The verified username names the actor of the request's audit events
    # (Audit::ActorResolver) — the configured one, never what was typed.
    def remember_http_basic_user
      request.env[PermissionForge::Audit::ActorResolver::BASIC_AUTH_ENV] = http_basic_auth_credentials[:user].to_s
    end

    # Records admin.auth_failed when credentials were sent: the username as
    # typed (capped, valid UTF-8), never the password. A browser's first
    # request, which sends none, is the challenge, not a failure.
    def audit_http_basic_failure(reason)
      return unless ActionController::HttpAuthentication::Basic.has_basic_credentials?(request)

      username = ActionController::HttpAuthentication::Basic.user_name_and_password(request).first
      PermissionForge::Audit::RequestContext.refused(
        self, 'admin.auth_failed', source: 'admin_ui',
                                   actor: { type: 'basic_auth', label: audit_username(username) },
                                   data: { 'reason' => reason }
      )
    end

    def audit_username(username)
      username.to_s.dup.force_encoding(Encoding::UTF_8).scrub.delete("\u0000")[0, AUDIT_USERNAME_LIMIT]
    end

    def http_basic_auth_enabled?
      PermissionForge.configuration.http_basic_auth_enabled
    end

    def http_basic_auth_configured?
      http_basic_auth_credentials.values.all?(&:present?)
    end

    def http_basic_auth_credentials
      {
        user: PermissionForge.configuration.http_basic_auth_user,
        password: PermissionForge.configuration.http_basic_auth_password
      }
    end
  end
end
