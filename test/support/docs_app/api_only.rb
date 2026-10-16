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

    module_function

    def run
      Application.boot!(skeleton: 'skeleton_api', api_only: true, forgery_protection: true)
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
        admin_post_with_middlewares: submit_new_set('From the admin'),
        admin_post_without_token: submit_new_set('Without a token', token: false) }
    end

    NEW_SET = '/permissions/permission_sets/new'

    # The admin's "New Permission Set" form as a browser submits it behind the
    # three middlewares: read from the page (its fields and authenticity
    # token, the session cookie kept), the name filled in, posted with
    # forgery protection on. `token: false` posts it without the token.
    def submit_new_set(name, token: true)
      browser = Rack::Test::Session.new(with_admin_middlewares)
      fields = form_fields(browser.get(NEW_SET, {}, BASIC).body, '/permissions/permission_sets').merge('name' => name)
      token_in_form = fields.key?('authenticity_token')
      fields.delete('authenticity_token') unless token
      posted(browser.post('/permissions/permission_sets', fields, BASIC), name).merge(token_in_form: token_in_form)
    rescue StandardError => e
      { status: nil, error: (e.cause || e).class.name, created: set?(name) }
    end

    def posted(response, name)
      { status: response.status, location: response.location&.sub(%r{\Ahttps?://[^/]+}, ''), created: set?(name) }
    end

    def set?(name) = PermissionForge::PermissionSet.exists?(name: name)

    # The fields a form posts: its inputs (checked radios and checkboxes only) and selects.
    def form_fields(html, action)
      form = form_posting_to(html, action)
      inputs = form.css('input[name]').select { |input| posts?(input) }.to_h { |input| [input['name'], input['value'].to_s] }
      inputs.merge(form.css('select[name]').to_h { |select| [select['name'], selected(select)] })
    end

    def form_posting_to(html, action)
      Nokogiri::HTML(html).css('form').find { |candidate| candidate['action'] == action } || raise("no form posts to #{action}")
    end

    def posts?(input) = !%w[radio checkbox].include?(input['type']) || input['checked']

    def selected(select) = select.at_css('option[selected]')&.[]('value').to_s

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
