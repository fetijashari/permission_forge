require 'test_helper'

module PermissionForge
  # The conditional-sets boot warning (BootChecks.warn_conditional_sets_without_context).
  # The cache warnings are covered by cache_warnings_test.rb, the channel
  # every boot warning takes by boot_warnings_channel_test.rb.
  class EngineWarningsTest < ActiveSupport::TestCase
    test 'warns when conditional sets exist but request_context_resolver returns empty context' do
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      create_permission_set(requires_session_flag: 'marketing_consent')
      PermissionForge.configuration.request_context_resolver = -> { {} }

      # Simulate the engine warning
      PermissionForge::BootChecks.warn_conditional_sets_without_context(PermissionForge.configuration)

      assert_match(/\[PermissionForge\] SECURITY warning: 1 permission set\(s\) use activation conditions/, log_output.string)
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
