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
    MASKING_WARNING = /auto-applied masking \(auto_apply_masked_attributes = :auto\) takes its models from the Resource rows/

    teardown do
      PermissionForge.configuration.cache_backend = :memory
      PermissionForge.configuration.auto_apply_masked_attributes = :auto
      PermissionForge.configuration.mask_virtual_attributes = false
    end

    test 'development with Rails.cache as a :memory_store warns, naming what happens and both remedies' do
      log = boot_log(env: 'development', backend: :rails_cache, rails_cache: ActiveSupport::Cache::MemoryStore.new)

      assert_match DEVELOPMENT_WARNING, log
      assert_match(/Rails\.cache is a :memory_store/, log)
      assert_match(%r{made in one process \(a console, `bin/rails runner`, a rake task or db:seed\) invalidates only that process's cache}, log)
      assert_match(/a running server keeps the permissions it has cached/, log)
      assert_match(/until cache_ttl \(#{PermissionForge.configuration.cache_ttl} s\)/, log)
      assert_match(%r{config\.cache_store = :file_store, "tmp/cache/store" in config/environments/development\.rb}, log)
      assert_match(/config\.cache_backend = :null/, log)
      assert_equal 1, log.scan(DEVELOPMENT_WARNING).size, 'logged once per boot'
    end

    # Field test: printed during `db:seed` and `bin/rails runner`, the
    # warning spoke of "this server" when no server ran.
    test 'the development warning reads right in any process, not only a server' do
      log = boot_log(env: 'development', backend: :memory)

      assert_no_match(/this server/, log)
      assert_match(/one per process/, log)
      assert_match(/config\.cache_backend = :null in development/, log)
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

    # Field test: under :auto a Resource row created from `bin/rails runner`
    # never reached the server through a :memory_store; the warning spoke of
    # stale permissions only.
    test 'development with a per-process store names the masking effect and its remedies' do
      log = boot_log(env: 'development', backend: :rails_cache, rails_cache: ActiveSupport::Cache::MemoryStore.new)

      assert_match MASKING_WARNING, log
      assert_match(/re-reads the Resource names from the database instead \(one query at most every 2 s\)/, log)
      assert_match(/in production a process would mask such a model only after a restart/, log)
      assert_match(/include PermissionForge::Concerns::MaskedAttributes in each model/, log)
      assert_match(/list the models in config\.auto_apply_masked_attributes/, log)
      assert_equal 1, log.scan(MASKING_WARNING).size, 'logged once per boot'
    end

    # Rails 7.1/7.2's development default: no stale permissions, but no token either.
    test 'development with a store that keeps nothing warns about masking only' do
      log = boot_log(env: 'development', backend: :rails_cache, rails_cache: ActiveSupport::Cache::NullStore.new)

      assert_match MASKING_WARNING, log
      assert_match(/one that keeps nothing \(Rails\.cache is a :null_store\)/, log)
      assert_no_match DEVELOPMENT_WARNING, log
    end

    test 'no masking warning when the masking settings are lists or off' do
      PermissionForge.configuration.auto_apply_masked_attributes = ['Customer']
      assert_no_match(/auto-applied masking/, boot_log(env: 'development', backend: :memory))

      PermissionForge.configuration.auto_apply_masked_attributes = false
      assert_no_match(/auto-applied masking/, boot_log(env: 'production', backend: :memory))
    end

    test 'mask_virtual_attributes = :auto alone is named in the masking warning' do
      PermissionForge.configuration.auto_apply_masked_attributes = false
      PermissionForge.configuration.mask_virtual_attributes = :auto

      assert_match(/auto-applied masking \(mask_virtual_attributes = :auto\)/, boot_log(env: 'development', backend: :memory))
    end

    test 'production with a per-process or a null store warns that masking is not announced' do
      [ActiveSupport::Cache::MemoryStore.new, ActiveSupport::Cache::NullStore.new].each do |store|
        log = boot_log(env: 'production', backend: :rails_cache, rails_cache: store)

        assert_match(/WARNING: auto-applied masking .* stays unmasked in this process until it restarts/, log, store.class)
        assert_match(/include PermissionForge::Concerns::MaskedAttributes/, log, store.class)
      end
    end

    # The boot logs before `bin/rails server` attaches its console logger,
    # and `bin/rails runner` never does: the warnings were in
    # log/development.log only (Warnings.emit decides the channel).
    test 'development writes both warnings to standard error as well, once each' do
      log = boot_log(env: 'development', backend: :memory)

      assert_equal 1, @stderr.scan(DEVELOPMENT_WARNING).size, @stderr
      assert_equal 1, @stderr.scan(MASKING_WARNING).size, @stderr
      assert_match DEVELOPMENT_WARNING, log
      assert_match MASKING_WARNING, log
    end

    test 'nothing on standard error when the logger already writes there' do
      with_rails_env('development', nil) do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
        out, err = capture_io do
          logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new($stdout)
          BootChecks.send(:warn_configuration, PermissionForge.configuration)
        ensure
          Rails.logger = logger
        end

        assert_match DEVELOPMENT_WARNING, out, 'logged'
        assert_empty err
      end
    end

    test 'nothing at all while a generator runs, and nothing on standard error in the test environment' do
      with_singleton_method(PermissionForge::Warnings, :generator_running?, -> { true }) do
        assert_empty boot_log(env: 'development', backend: :memory)
        assert_empty @stderr
      end
      boot_log(env: 'test', backend: :memory)
      assert_empty @stderr
    end

    # A production console, runner, rake task or job worker (the test runner
    # is no server either): its log is not read, so the terminal gets a copy.
    test 'production writes to standard error in a process that is not a server' do
      log = boot_log(env: 'production', backend: :memory)

      assert_match(/in-process permission cache in production/, log)
      assert_equal 1, @stderr.scan('in-process permission cache in production').size, @stderr

      with_singleton_method(PermissionForge::Warnings, :server_process?, -> { true }) do
        assert_match(/in-process permission cache in production/, boot_log(env: 'production', backend: :memory))
        assert_empty @stderr, 'a server: the log is the record'
      end
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
      store = ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://127.0.0.1:1/15', pool: false)

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
    # What it writes to standard error is left in @stderr. Each boot is a
    # fresh process (the terminal gets a key once per process).
    def boot_log(env:, backend:, rails_cache: nil)
      with_rails_env(env, rails_cache) do
        PermissionForge.configuration.cache_backend = backend
        PermissionForge.configuration.reset_cache_store!
        PermissionForge::Warnings.reset!
        log = nil
        _, @stderr = capture_io do
          log = capture_rails_log { BootChecks.send(:warn_configuration, PermissionForge.configuration) }
        end
        log
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
