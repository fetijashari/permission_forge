# frozen_string_literal: true

module PermissionForge
  module Audit
    # The one answer to "may this request read the audit log?", asked by the
    # JSON API endpoint and by the HTML pages and exports alike.
    #
    # The request has already passed the surface's own gate (api_enabled and
    # api_auth for the API, the admin authentication for the HTML pages) by the
    # time this is asked, so with `config.audit_log_authorization` unset the
    # answer is yes: reading the log needs no more than the admin access that
    # reading every other admin endpoint needs.
    #
    # With a lambda(controller) set, only an exact `true` allows. Anything else
    # (false, nil, a truthy non-true value) denies, and so does a lambda that
    # raises: an authorization hook that fails must never open the log.
    #
    # @api private
    module LogAccess
      class << self
        # @param controller [ActionController::Base] the request's controller
        # @param configuration [PermissionForge::Configuration]
        # @return [Boolean]
        def allowed?(controller, configuration: PermissionForge.configuration)
          hook = configuration.audit_log_authorization
          return true if hook.nil?

          true.equal?(hook.call(controller))
        rescue StandardError => e
          Failure.handle(e, strategy: :report, operation: :authorize, hook: 'audit_log_authorization')
          false
        end
      end
    end
  end
end
