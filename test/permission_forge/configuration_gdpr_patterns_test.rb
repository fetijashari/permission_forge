require 'test_helper'

module PermissionForge
  class ConfigurationGdprPatternsTest < ActiveSupport::TestCase
    setup do
      @config = PermissionForge::Configuration.new
    end

    test 'valid regex patterns are accepted' do
      assert_nothing_raised do
        @config.gdpr_field_patterns = { /\Aemail\z/ => 'email', /phone/ => 'last4' }
      end
    end

    test 'invalid regex string raises ConfigurationError' do
      assert_raises(PermissionForge::ConfigurationError) do
        @config.gdpr_field_patterns = { '[unclosed' => 'full' }
      end
    end

    test 'error message includes the pattern name' do
      error = assert_raises(PermissionForge::ConfigurationError) do
        @config.gdpr_field_patterns = { '[bad' => 'full' }
      end
      assert_match(/\[bad/, error.message)
    end

    test 'mix of valid and invalid raises on the invalid one' do
      assert_raises(PermissionForge::ConfigurationError) do
        @config.gdpr_field_patterns = { /valid/ => 'full', '[unclosed' => 'last4' }
      end
    end

    test 'Regexp objects are accepted without validation' do
      assert_nothing_raised do
        @config.gdpr_field_patterns = { Regexp.new('email') => 'email' }
      end
    end

    test 'empty patterns hash is accepted' do
      assert_nothing_raised do
        @config.gdpr_field_patterns = {}
      end
    end

    test 'changing patterns after initial set re-validates' do
      @config.gdpr_field_patterns = { /valid/ => 'full' }
      assert_raises(PermissionForge::ConfigurationError) do
        @config.gdpr_field_patterns = { '[broken' => 'last4' }
      end
    end
  end
end
