# frozen_string_literal: true

require 'test_helper'
require 'open3'

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

    # A `rails new --api` host that mounts the engine and counts its route draws.
    HOST_SCRIPT = <<~RUBY
      require 'json'
      require 'tmpdir'
      require 'stringio'
      require 'logger'
      require 'rails'
      require 'active_record/railtie'
      require 'action_controller/railtie'
      $LOAD_PATH.unshift(%<lib>s)
      require 'permission_forge'
      root = Dir.mktmpdir('pf_api_only_routes')
      Dir.mkdir(File.join(root, 'config'))
      File.write(File.join(root, 'config/routes.rb'),
                 "$pf_draws += 1\nRails.application.routes.draw { mount PermissionForge::Engine, at: '/permissions' }\n")
      $pf_draws = 0
      LOG = StringIO.new
      ENV['DATABASE_URL'] = 'sqlite3::memory:'
      Class.new(Rails::Application) do
        config.root = root
        config.eager_load = %<eager_load>s
        config.api_only = true
        config.secret_key_base = 'x' * 32
        config.logger = Logger.new(LOG)
        config.active_support.deprecation = :silence
        config.hosts.clear
      end
      PermissionForge.configure { |config| config.api_only_admin_warning = %<warning>s }
      Rails.application.initialize!
      count = -> { [$pf_draws, LOG.string.scan('The application is API-only').size] }
      facts = { boot: count.call }
      2.times { Rack::MockRequest.new(Rails.application).get('/permissions/api/permission_sets') }
      facts[:requests] = count.call
      puts JSON.generate(facts)
    RUBY

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

    test 'config.api_only_admin_warning = false silences the warning (an app that uses only the JSON API)' do
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)
      configuration = Configuration.new
      assert_equal true, configuration.api_only_admin_warning
      configuration.api_only_admin_warning = false
      BootChecks.warn_api_only_admin(host(api_only: true, stack: API_ONLY_STACK), config: configuration)
      assert_empty log.string
      configuration.api_only_admin_warning = true
      BootChecks.warn_api_only_admin(host(api_only: true, stack: API_ONLY_STACK), config: configuration)
      assert_includes log.string, 'config.api_only = true'
    ensure
      Rails.logger = original
    end

    # A real `rails new --api` host in a child process (development), with
    # eager_load off (Rails 8 draws the routes at their first use) and on (at boot): the
    # warning comes once the routes are drawn, the routes are drawn once —
    # the check never draws them itself — and a second request warns no more.
    test 'the warning comes when the routes are drawn, which the check never does itself' do
      lazy = api_only_host(eager_load: false)
      eager = api_only_host(eager_load: true)
      assert_equal [1, 1], eager['boot'], 'eager_load: drawn at boot, warned at boot'
      assert_equal [1, 1], eager['requests'], eager.inspect
      if Rails::VERSION::MAJOR >= 8
        assert_equal [0, 0], lazy['boot'], 'Rails 8 draws the routes at their first use: nothing at boot'
      else
        assert_equal [1, 1], lazy['boot'], 'Rails 7 draws the routes at boot'
      end
      assert_equal [1, 1], lazy['requests'], "drawn once, warned once: #{lazy.inspect}"
      assert_equal [1, 0], api_only_host(eager_load: true, warning: false)['requests'], 'api_only_admin_warning = false'
    end

    private

    # [route draws, api_only_admin warnings in the log] after the boot and after two requests.
    def api_only_host(eager_load:, warning: true)
      script = format(HOST_SCRIPT, lib: File.expand_path('../../lib', __dir__).inspect, eager_load: eager_load, warning: warning)
      # development: where Rails 8 draws the routes lazily (Rails.env.local?)
      output, status = Open3.capture2e({ 'RAILS_ENV' => 'development' }, RbConfig.ruby, '-e', script)
      assert status.success?, output
      JSON.parse(output.lines.reverse.find { |line| line.start_with?('{') })
    end
  end
end
