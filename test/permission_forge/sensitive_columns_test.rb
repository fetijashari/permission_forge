# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # PermissionForge::SensitiveColumns — the one definition of "this column
  # looks like personal data, with this mask": config.gdpr_field_patterns,
  # then the host's filter_parameters while filter_parameters_integration is
  # on. The admin (presets, Sync, the Fields tab, Home), the field generator,
  # the GDPR audit and the boot warning all ask it (decision_parity_test).
  class SensitiveColumnsTest < ActiveSupport::TestCase
    setup do
      @deprecator = PermissionForge.deprecator
      @saved_behavior = @deprecator.behavior
      @warnings = []
      @deprecator.behavior = ->(message, *) { @warnings << message }
    end

    teardown do
      @deprecator.behavior = @saved_behavior
    end

    test 'matches gdpr patterns with the alternative that matched, its strategy and the source' do
      match = SensitiveColumns.new.match('national_id')

      assert_equal 'national_id', match.pattern
      assert_equal 'last4', match.strategy
      assert_equal :gdpr_pattern, match.source
      assert_not match.filter_parameter?
      assert_nil SensitiveColumns.new.match('status')
      assert SensitiveColumns.new.sensitive?('email')
    end

    test 'a host filter_parameters entry is personal data, masked fully, while the integration is on' do
      PermissionForge.configuration.filter_parameters_integration = true
      match = SensitiveColumns.new(filter_parameters: [:secret_code]).match('secret_code')

      assert_equal 'full', match.strategy
      assert_equal 'filter_parameters', match.pattern
      assert_equal :filter_parameters, match.source
      assert match.filter_parameter?

      PermissionForge.configuration.filter_parameters_integration = false
      assert_nil SensitiveColumns.new(filter_parameters: [:secret_code]).match('secret_code')
    end

    test 'a gdpr pattern wins over a filter_parameters entry naming the same column' do
      PermissionForge.configuration.filter_parameters_integration = true
      match = SensitiveColumns.new(filter_parameters: [:email]).match('email')

      assert_equal 'email', match.strategy
      assert_equal :gdpr_pattern, match.source
    end

    test 'takes an injected configuration' do
      configuration = PermissionForge::Configuration.new
      configuration.gdpr_field_patterns = { /\Acodename\z/ => 'last4' }

      assert_equal 'last4', SensitiveColumns.new(configuration: configuration).match('codename').strategy
      assert_nil SensitiveColumns.new(configuration: configuration).match('email')
    end

    test 'PermissionForge::Admin::SensitiveColumns is a deprecated name for the same class' do
      assert_same PermissionForge::SensitiveColumns, PermissionForge::Admin::SensitiveColumns
      assert_equal 1, @warnings.size
      assert_match(/PermissionForge::Admin::SensitiveColumns is deprecated! Use PermissionForge::SensitiveColumns instead/, @warnings.first)
    end
  end
end
