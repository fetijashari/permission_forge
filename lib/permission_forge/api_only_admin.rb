# frozen_string_literal: true

module PermissionForge
  # The admin screens in an API-only application (`rails new --api`,
  # `config.api_only = true`). Rails then leaves ActionDispatch::Cookies, the
  # session store and ActionDispatch::Flash out of the middleware stack, and
  # every admin page that renders a form raises: NameError for `flash` (its
  # request methods are loaded with the middleware), then
  # ActionDispatch::Request::Session::DisabledSessionError for the CSRF
  # token. The JSON API needs none of them. BootChecks warns through
  # Warnings.emit (:api_only_admin), naming the middlewares
  # config/application.rb must add, when the engine is mounted.
  #
  # @api private
  module ApiOnlyAdmin
    COOKIES = 'ActionDispatch::Cookies'
    SESSION = 'ActionDispatch::Session::CookieStore'
    FLASH = 'ActionDispatch::Flash'
    # What each one is recognised by in the stack: any session store counts.
    PRESENT = {
      COOKIES => ->(name) { name == COOKIES },
      SESSION => ->(name) { name.start_with?('ActionDispatch::Session::') },
      FLASH => ->(name) { name == FLASH }
    }.freeze

    module_function

    # @param application [Rails::Application]
    # @return [Array<String>] the middlewares the admin needs that the stack
    #   lacks; empty unless the application is api_only with the engine mounted
    def missing_middlewares(application)
      return [] unless api_only?(application) && mounted?(application)

      names = middleware_names(application)
      return [] if names.nil?

      PRESENT.reject { |_name, present| names.any?(&present) }.keys
    end

    def api_only?(application)
      application.respond_to?(:config) && application.config.respond_to?(:api_only) && application.config.api_only == true
    end

    # @param missing [Array<String>]
    # @return [String] the warning
    def message(missing)
      'The application is API-only (config.api_only = true) and PermissionForge::Engine is mounted: the admin screens ' \
        "need #{missing.join(', ')} in the middleware stack, which an API-only application leaves out. Every admin page " \
        "that renders a form answers 500 until config/application.rb adds #{missing.map { |name| "config.middleware.use #{name}" }.join(', ')} " \
        '(docs/admin-ui.md#api-only-applications). The JSON API works without them.'
    end

    # The names in the built stack (after initialize!); nil while it is still
    # the configuration proxy, when nothing can be said yet.
    def middleware_names(application)
      stack = application.middleware
      return nil unless stack.respond_to?(:middlewares)

      stack.middlewares.map { |middleware| middleware.name.to_s }
    rescue StandardError
      nil
    end

    # Whether the engine is mounted. Rails 7.2+ draws the routes lazily when
    # eager_load is off, so at boot they are still empty and are drawn first
    # (reload_routes!, canary :lazy_routes); when they cannot be read, yes (a
    # warning too many beats a 500 nobody was told about).
    def mounted?(application)
      application.reload_routes! if application.routes.routes.empty?
      application.routes.routes.any? { |route| engine?(route.app) }
    rescue StandardError
      true
    end

    def engine?(app)
      app == PermissionForge::Engine || (app.respond_to?(:app) && app.app == PermissionForge::Engine)
    end
  end
end
