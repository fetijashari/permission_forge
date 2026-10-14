# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class SecureDefaultsTest < ActiveSupport::TestCase
      # Tests verify that the gem ships with secure defaults.
      # The test_helper overrides some of these for test convenience,
      # so we test a fresh Configuration instance.

      setup do
        @config = PermissionForge::Configuration.new
      end

      test 'unconfigured_field_strategy defaults to :block' do
        assert_equal :block, @config.unconfigured_field_strategy
      end

      test 'nested_attributes_parent_fallback defaults to false (a nested payload for an ungranted model is dropped)' do
        assert_equal false, @config.nested_attributes_parent_fallback
      end

      test 'api_stats_require_admin defaults to true' do
        assert_equal true, @config.api_stats_require_admin
      end

      test 'filter_parameters_integration defaults to true' do
        assert_equal true, @config.filter_parameters_integration
      end

      test 'nil_user_strategy defaults to :bypass for backward compatibility' do
        assert_equal :bypass, @config.nil_user_strategy
      end

      test 'api_action_authorization defaults to nil' do
        assert_nil @config.api_action_authorization
      end

      test 'api_assignment_authorization defaults to nil' do
        assert_nil @config.api_assignment_authorization
      end

      test 'on_rule_bypass defaults to nil' do
        assert_nil @config.on_rule_bypass
      end

      test 'api_max_per_page defaults to 100' do
        assert_equal 100, @config.api_max_per_page
      end

      test 'api_default_per_page defaults to 15' do
        assert_equal 15, @config.api_default_per_page
      end

      test 'api_enabled defaults to false' do
        assert_equal false, @config.api_enabled
      end

      test 'api_require_authorization defaults to true (identity alone may not change permissions)' do
        assert_equal true, @config.api_require_authorization
      end

      test 'api_auth defaults to nil (401 safe default)' do
        assert_nil @config.api_auth
      end
    end
  end
end
