# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The api_only_admin boot warning (BootChecks.warn_api_only_admin,
  # ApiOnlyAdmin): an API-only application that mounts the engine is told
  # which middlewares its admin screens need. The application is a stand-in
  # here; test/permission_forge/docs/doc_samples_test.rb boots a real
  # `rails new --api` host and reads the warning from its log.
  class BootChecksApiOnlyTest < ActiveSupport::TestCase
    Middleware = Struct.new(:name)
    Stack = Struct.new(:middlewares)
    Route = Struct.new(:app)
    Routes = Struct.new(:routes)
    Config = Struct.new(:api_only)
    Host = Struct.new(:config, :middleware, :routes)

    API_ONLY_STACK = %w[ActionDispatch::HostAuthorization Rack::Runtime ActionDispatch::Executor ActionDispatch::Callbacks].freeze
    FULL_STACK = (API_ONLY_STACK + %w[ActionDispatch::Cookies ActionDispatch::Session::CookieStore ActionDispatch::Flash]).freeze

    def host(api_only:, stack:, mounted: true)
      routes = Routes.new(mounted ? [Route.new(PermissionForge::Engine)] : [Route.new(Object.new)])
      Host.new(Config.new(api_only), Stack.new(stack.map { |name| Middleware.new(name) }), routes)
    end

    test 'an api_only application that mounts the engine lacks the three middlewares' do
      assert_equal %w[ActionDispatch::Cookies ActionDispatch::Session::CookieStore ActionDispatch::Flash],
                   ApiOnlyAdmin.missing_middlewares(host(api_only: true, stack: API_ONLY_STACK))
    end

    test 'any session store counts, and an application that added the three is not warned' do
      assert_empty ApiOnlyAdmin.missing_middlewares(host(api_only: true, stack: FULL_STACK))
      cache_store = API_ONLY_STACK + %w[ActionDispatch::Cookies ActionDispatch::Session::CacheStore ActionDispatch::Flash]
      assert_empty ApiOnlyAdmin.missing_middlewares(host(api_only: true, stack: cache_store))
    end

    test 'a full application, an api_only one that does not mount the engine, and a stack not built yet are not warned' do
      assert_empty ApiOnlyAdmin.missing_middlewares(host(api_only: false, stack: API_ONLY_STACK))
      assert_empty ApiOnlyAdmin.missing_middlewares(host(api_only: true, stack: API_ONLY_STACK, mounted: false))
      proxy = Host.new(Config.new(true), Object.new, Routes.new([Route.new(PermissionForge::Engine)]))
      assert_empty ApiOnlyAdmin.missing_middlewares(proxy)
      assert_empty ApiOnlyAdmin.missing_middlewares(nil)
    end

    test 'the warning goes through the emitter and names the middlewares and the lines to add' do
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)
      BootChecks.warn_api_only_admin(host(api_only: true, stack: API_ONLY_STACK))
      line = log.string
      assert_match(/\A\[PermissionForge\] The application is API-only \(config\.api_only = true\)/, line.sub(/\A[^\[]*/, ''))
      %w[config.middleware.use ActionDispatch::Cookies config.middleware.use ActionDispatch::Session::CookieStore
         config.middleware.use ActionDispatch::Flash docs/admin-ui.md#api-only-applications].each { |text| assert_includes line, text }
      assert_no_match(/SECURITY warning/, line, 'a 500 is not a fail-open condition')
    ensure
      Rails.logger = original
    end

    test 'the real application is not warned (the dummy app is not api_only)' do
      assert_empty ApiOnlyAdmin.missing_middlewares(Rails.application)
    end
  end
end
