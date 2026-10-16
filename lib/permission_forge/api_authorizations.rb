# frozen_string_literal: true

module PermissionForge
  # The JSON API's authorization lambdas, and what the API refuses while one
  # it needs is unset. `api_auth` proves identity only: while
  # api_require_authorization is on (the default) a change needs
  # api_action_authorization and an assignment api_assignment_authorization,
  # and while api_stats_require_admin is on (the default) GET /api/stats
  # needs api_stats_authorization. Without one, the API answers 403 and the
  # answer names the option: it fails closed, but nothing said so before the
  # first refused request (field test round 8, D#7). The boot note
  # (BootChecks, :api_authorization_unset) and the audit finding
  # (ConfigCheck#api_authorization_unset) both read `unset`.
  #
  # The stats note cannot see an api_auth that still sets the deprecated
  # 0.14 `@admin = true` on the controller (Api::DashboardController
  # #legacy_admin_flag?, until 0.16): that host is not refused, and the note
  # says so.
  #
  # api_require_authorization = false with a lambda unset is another
  # condition (every caller api_auth admits may change permissions: the
  # api_authorization_gap warning, the api_mutations_unguarded finding).
  #
  # @api private
  module ApiAuthorizations
    # Each lambda => [the setting under which the API needs it, what the API
    # refuses (403) while it is unset].
    LAMBDAS = {
      api_action_authorization: [:api_require_authorization, 'every create, update, delete and copy'],
      api_assignment_authorization: [:api_require_authorization, 'every assignment and group membership change'],
      api_stats_authorization: [:api_stats_require_admin,
                                'GET /api/stats (or set api_stats_require_admin = false; an api_auth that sets the ' \
                                'deprecated @admin = true still passes until 0.16)']
    }.freeze

    module_function

    # The lambdas the API needs and does not have. None while the API is off
    # or api_auth is unset (every request is then a 401).
    #
    # @param config [Configuration]
    # @return [Hash{Symbol => String}] lambda option => what the API refuses without it
    def unset(config)
      return {} unless config.api_enabled && config.api_auth

      LAMBDAS.each_with_object({}) do |(option, (required_by, refused)), unset|
        unset[option] = refused if config.public_send(required_by) && !config.public_send(option)
      end
    end

    # One line per unset lambda: "<option>: <what is refused>".
    #
    # @param config [Configuration]
    # @return [Array<String>]
    def lines(config)
      unset(config).map { |option, refused| "#{option}: #{refused}" }
    end
  end
end
