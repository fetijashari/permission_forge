# frozen_string_literal: true

module DocsApp
  # A `rails new --api` host (config.api_only: no cookies, session or flash
  # middleware; ActionController::API): the JSON API works, the admin
  # screens need the three middlewares the docs name, and the boot says so.
  module ApiOnly
    API_KEY = 'docs-key'
    BASIC = { 'HTTP_AUTHORIZATION' => "Basic #{Base64.strict_encode64('admin:docs')}" }.freeze
    KEY = { 'HTTP_X_API_KEY' => API_KEY }.freeze
    JSON_BODY = { 'CONTENT_TYPE' => 'application/json' }.freeze
    FORM = { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }.freeze

    module_function

    def run
      Application.boot!(skeleton: 'skeleton_api', api_only: true)
      Fixtures.host_tables!
      User.create!(email_address: Fixtures.email(:alice), password_digest: 'none', name: 'Alice Admin', admin: true)
      install = Install.from_readme!
      configure!
      { mode: 'api_only', rails: Rails.version, api_only: Rails.application.config.api_only, install: install,
        boot_warning: boot_warning }.merge(api_checks, admin_checks)
    end

    def configure!
      PermissionForge.configure do |config|
        config.api_enabled = true
        config.api_auth = ->(controller) { controller.request.headers['X-Api-Key'] == API_KEY }
        config.api_action_authorization = ->(_controller, _action, _record) { true }
        config.api_assignment_authorization = ->(_controller, _set, _user_ids) { true }
        config.http_basic_auth_user = 'admin'
        config.http_basic_auth_password = 'docs'
      end
    end

    # The api_only_admin warning, as the log got it at boot.
    def boot_warning
      File.readlines(Application.log).find { |line| line.include?('config.api_only') }&.strip
    end

    def api_checks
      { api_list_with_key: call(:get, '/permissions/api/permission_sets', KEY)[:status],
        api_list_without_key: call(:get, '/permissions/api/permission_sets')[:status],
        api_create_with_key: call(:post, '/permissions/api/permission_sets', KEY.merge(JSON_BODY),
                                  body: JSON.generate(permission_set: { name: 'From the API' }))[:status] }
    end

    # The admin without the middlewares (what the host has), then behind the
    # three the docs say to add — the same application, nothing rebooted.
    def admin_checks
      { admin_page_without_middlewares: call(:get, '/permissions/', BASIC),
        admin_page_with_middlewares: call(:get, '/permissions/', BASIC, app: with_admin_middlewares),
        admin_post_with_middlewares: call(:post, '/permissions/permission_sets', BASIC.merge(FORM), app: with_admin_middlewares,
                                                                                                    body: 'permission_set[name]=From+the+admin') }
    end

    # Naming ActionDispatch::Flash loads it, as `config.middleware.use` does:
    # that is what gives ActionDispatch::Request its `flash`.
    def with_admin_middlewares
      ActionDispatch::Cookies.new(ActionDispatch::Session::CookieStore.new(ActionDispatch::Flash.new(Rails.application), key: '_docs_session'))
    end

    # One request; an exception (show_exceptions :none) is reported by class.
    def call(verb, path, headers = {}, app: Rails.application, body: nil)
      env = Rack::MockRequest.env_for("http://localhost#{path}", headers.merge(method: verb.to_s.upcase, input: body))
      status, _headers, response = app.call(env)
      response.close if response.respond_to?(:close)
      { status: status }
    rescue StandardError => e
      { status: nil, error: (e.cause || e).class.name, message: (e.cause || e).message.lines.first.to_s.strip }
    end
  end
end
