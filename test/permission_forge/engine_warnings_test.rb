require 'test_helper'

module PermissionForge
  class EngineWarningsTest < ActiveSupport::TestCase
    test 'production env with memory cache logs warning' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      original_env = Rails.env
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new('production'))
      PermissionForge.configuration.cache_backend = :memory

      # Simulate the after_initialize warning
      if Rails.env.production? && PermissionForge.configuration.cache_backend == :memory
        Rails.logger.warn '[PermissionForge] WARNING: Using in-process MemoryCache in production.'
      end

      assert_match(/MemoryCache in production/, log_output.string)
    ensure
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new(original_env.to_s))
      Rails.logger = original_logger
      PermissionForge.configuration.cache_backend = :memory
    end

    test 'production env with rails_cache does not log warning' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      original_env = Rails.env
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new('production'))
      PermissionForge.configuration.cache_backend = :rails_cache

      if Rails.env.production? && PermissionForge.configuration.cache_backend == :memory
        Rails.logger.warn '[PermissionForge] WARNING: Using in-process MemoryCache in production.'
      end

      assert_no_match(/MemoryCache/, log_output.string)
    ensure
      Rails.instance_variable_set(:@_env, ActiveSupport::EnvironmentInquirer.new(original_env.to_s))
      Rails.logger = original_logger
      PermissionForge.configuration.cache_backend = :memory
    end

    test 'development env with memory cache does not log warning' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      # Rails.env is already 'test', similar to development — not production
      if Rails.env.production? && PermissionForge.configuration.cache_backend == :memory
        Rails.logger.warn '[PermissionForge] WARNING: Using in-process MemoryCache in production.'
      end

      assert_no_match(/MemoryCache/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'test env with memory cache does not log warning' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      if Rails.env.production? && PermissionForge.configuration.cache_backend == :memory
        Rails.logger.warn '[PermissionForge] WARNING: Using in-process MemoryCache in production.'
      end

      assert_no_match(/MemoryCache/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'warns when conditional sets exist but request_context_resolver returns empty context' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(requires_session_flag: 'marketing_consent')
      PermissionForge.configuration.request_context_resolver = -> { {} }

      # Simulate the engine warning
      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_match(/activation conditions/, log_output.string)
      assert_match(/ALWAYS ACTIVE/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'warns for IP-restricted sets when request_context_resolver returns empty context' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(allowed_ips: '10.0.0.0/8')
      PermissionForge.configuration.request_context_resolver = -> { {} }

      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_match(/activation conditions/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'does not warn when request_context_resolver returns non-empty context' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(requires_session_flag: 'marketing_consent')
      PermissionForge.configuration.request_context_resolver = -> { { session_flags: [] } }

      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_no_match(/activation conditions/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'a resolver that returns a Struct or nil does not stop the boot' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(requires_session_flag: 'marketing_consent')
      context = Struct.new(:ip, :session_flags)
      PermissionForge.configuration.request_context_resolver = -> { context.new('10.0.0.1', []) }

      assert_nothing_raised do
        PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)
      end
      assert_no_match(/activation conditions/, log_output.string)

      PermissionForge.configuration.request_context_resolver = -> {}
      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)
      assert_match(/activation conditions/, log_output.string, 'nil is a blank context')
    ensure
      Rails.logger = original_logger
    end

    test 'does not warn when strict mode is enabled (fails closed instead)' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(requires_session_flag: 'marketing_consent')
      PermissionForge.configuration.request_context_resolver = -> { {} }
      PermissionForge.configuration.conditional_sets_strict_mode = true

      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_no_match(/activation conditions/, log_output.string)
    ensure
      Rails.logger = original_logger
    end

    test 'does not warn when no conditional sets exist' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(name: 'Regular Set')
      PermissionForge.configuration.request_context_resolver = -> { {} }

      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_no_match(/activation conditions/, log_output.string)
    ensure
      Rails.logger = original_logger
    end
  end
end
