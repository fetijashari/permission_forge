require 'test_helper'
require_relative '../support/boot_test_helpers'

module PermissionForge
  # The boot warning about a permission cache that lives in each process:
  # in development a change made from a console, runner or rake task never
  # reaches the running server (Rails 8's development cache_store is a
  # :memory_store, and the generated initializer caches through Rails.cache).
  class CacheWarningsTest < ActiveSupport::TestCase
    include BootTestHelpers

    DEVELOPMENT_WARNING = /\[PermissionForge\] Development: the permission cache is .*one per process/

    teardown do
      PermissionForge.configuration.cache_backend = :memory
    end

    test 'development with Rails.cache as a :memory_store warns, naming what happens and both remedies' do
      log = boot_log(env: 'development', backend: :rails_cache, rails_cache: ActiveSupport::Cache::MemoryStore.new)

      assert_match DEVELOPMENT_WARNING, log
      assert_match(/Rails\.cache is a :memory_store/, log)
      assert_match(%r{console, `bin/rails runner` or a rake task invalidates only that process's cache}, log)
      assert_match(/until cache_ttl \(#{PermissionForge.configuration.cache_ttl} s\)/, log)
      assert_match(%r{config\.cache_store = :file_store, "tmp/cache/store" in config/environments/development\.rb}, log)
      assert_match(/config\.cache_backend = :null/, log)
      assert_equal 1, log.scan(DEVELOPMENT_WARNING).size, 'logged once per boot'
    end

    test 'development with cache_backend = :memory warns' do
      log = boot_log(env: 'development', backend: :memory)

      assert_match DEVELOPMENT_WARNING, log
      assert_match(/cache_backend = :memory\)/, log)
    end

    test 'development with a MemoryStore instance as cache_backend warns' do
      log = boot_log(env: 'development', backend: ActiveSupport::Cache::MemoryStore.new)

      assert_match(/cache_backend is an ActiveSupport::Cache::MemoryStore/, log)
    end

    test 'development with a shared or a null store does not warn' do
      Dir.mktmpdir do |dir|
        {
          file_store: ActiveSupport::Cache::FileStore.new(dir),
          null_store: ActiveSupport::Cache::NullStore.new
        }.each do |name, store|
          log = boot_log(env: 'development', backend: :rails_cache, rails_cache: store)
          assert_no_match DEVELOPMENT_WARNING, log, name
          assert_no_match DEVELOPMENT_WARNING, boot_log(env: 'development', backend: store), name
        end
      end
      assert_no_match DEVELOPMENT_WARNING, boot_log(env: 'development', backend: :null)
    end

    test 'a Redis store does not warn in development' do
      store = ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://127.0.0.1:1/15')

      assert_no_match DEVELOPMENT_WARNING, boot_log(env: 'development', backend: store)
    rescue LoadError
      skip 'the redis gem is not available'
    end

    test 'the test environment does not warn' do
      log = boot_log(env: 'test', backend: :rails_cache, rails_cache: ActiveSupport::Cache::MemoryStore.new)

      assert_no_match DEVELOPMENT_WARNING, log
      assert_no_match(/in-process permission cache/, log)
    end

    test 'production gets the production warning, not the development one' do
      log = boot_log(env: 'production', backend: :rails_cache, rails_cache: ActiveSupport::Cache::MemoryStore.new)

      assert_no_match DEVELOPMENT_WARNING, log
      assert_match(/in-process permission cache in production/, log)
    end

    test 'production with a shared store does not warn' do
      Dir.mktmpdir do |dir|
        log = boot_log(env: 'production', backend: :rails_cache, rails_cache: ActiveSupport::Cache::FileStore.new(dir))

        assert_no_match(/in-process permission cache/, log)
      end
    end

    private

    # What the configuration boot warnings log under `env`, with
    # `backend` as cache_backend and, when given, `rails_cache` as Rails.cache.
    def boot_log(env:, backend:, rails_cache: nil)
      with_rails_env(env, rails_cache) do
        PermissionForge.configuration.cache_backend = backend
        PermissionForge.configuration.reset_cache_store!
        capture_rails_log { BootChecks.send(:warn_configuration, PermissionForge.configuration) }
      end
    ensure
      PermissionForge.configuration.reset_cache_store!
    end

    def with_rails_env(env, rails_cache)
      original_env = Rails.env
      original_cache = Rails.cache
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new(env))
      Rails.cache = rails_cache if rails_cache
      yield
    ensure
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new(original_env.to_s))
      Rails.cache = original_cache
    end
  end
end
