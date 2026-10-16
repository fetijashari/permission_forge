# frozen_string_literal: true

module DocsApp
  # Boots the Rails application of the docs app from a skeleton copied into a
  # temp directory: what `rails new` configures for the test environment,
  # with reloading on (the docs' `file=` blocks replace app files after the
  # boot, as an editor would in development).
  module Application
    module_function

    def root = @root ||= Dir.mktmpdir('pf_docs_app').tap { |dir| at_exit { FileUtils.remove_entry(dir) if File.directory?(dir) } }

    def log = File.join(root, 'log/test.log')

    # @param skeleton [String] the directory under docs_app/ to copy
    # @param api_only [Boolean] a `rails new --api` host
    # @param serve [Boolean] what a browser needs: forgery protection, a cache, Rails' error pages
    def boot!(skeleton:, api_only: false, serve: false)
      FileUtils.cp_r(File.join(SKELETONS, skeleton, '.'), root)
      %w[config/initializers db/migrate log tmp public].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
      Dir.chdir(root)
      define(api_only: api_only, serve: serve)
      Rails.application.initialize!
    end

    def define(api_only:, serve:)
      Class.new(Rails::Application) do
        Application.basics(config)
        Application.web(config, api_only: api_only, serve: serve)
      end
    end

    # What `rails new` writes for every environment: the root, the defaults,
    # no eager loading, reloading on, a logger of its own.
    def basics(config)
      config.root = root
      config.load_defaults Rails::VERSION::STRING.to_f
      config.eager_load = false
      config.enable_reloading = true
      config.secret_key_base = 'docs-app-' * 8
      config.logger = Logger.new(log)
      config.log_level = :info
      config.active_support.deprecation = :silence
    end

    # The test-environment settings, and what a browser needs when served.
    def web(config, api_only:, serve:)
      config.hosts.clear
      config.api_only = api_only
      config.cache_store = serve ? :memory_store : :null_store
      config.action_dispatch.show_exceptions = serve ? :all : :none
      config.consider_all_requests_local = false
      config.action_controller.allow_forgery_protection = serve
      config.action_controller.raise_on_missing_callback_actions = false
    end

    # The whole app, reloaded: every file the docs wrote is read again, and
    # the engine's to_prepare (MaskingSync.reloaded!) re-applies masking to
    # the fresh classes.
    def reload!
      Rails.application.reloader.reload!
    end
  end
end
