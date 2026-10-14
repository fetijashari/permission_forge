require 'test_helper'

module PermissionForge
  class ConfigurationGdprTest < ActiveSupport::TestCase
    test 'gdpr_defaults defaults to true on fresh config' do
      config = PermissionForge::Configuration.new
      assert config.gdpr_defaults
    end

    test 'setting gdpr_defaults to false explicitly works' do
      config = PermissionForge::Configuration.new
      config.gdpr_defaults = false
      assert_not config.gdpr_defaults
    end

    test 'gdpr_require_explicit_choice without setting gdpr_defaults raises ConfigurationError' do
      config = PermissionForge::Configuration.new
      config.gdpr_require_explicit_choice = true
      # gdpr_defaults is NOT explicitly set (just using the default)
      assert_raises(PermissionForge::ConfigurationError) do
        config.validate_gdpr_explicit_choice!
      end
    end

    test 'gdpr_require_explicit_choice with gdpr_defaults explicitly set does not raise' do
      config = PermissionForge::Configuration.new
      config.gdpr_require_explicit_choice = true
      config.gdpr_defaults = true
      assert_nothing_raised do
        config.validate_gdpr_explicit_choice!
      end
    end

    test 'gdpr_require_explicit_choice with gdpr_defaults explicitly set to false does not raise' do
      config = PermissionForge::Configuration.new
      config.gdpr_require_explicit_choice = true
      config.gdpr_defaults = false
      assert_nothing_raised do
        config.validate_gdpr_explicit_choice!
      end
    end

    test 'gdpr_require_explicit_choice false does not raise regardless' do
      config = PermissionForge::Configuration.new
      config.gdpr_require_explicit_choice = false
      assert_nothing_raised do
        config.validate_gdpr_explicit_choice!
      end
    end

    test 'gdpr_require_explicit_choice defaults to false' do
      config = PermissionForge::Configuration.new
      assert_not config.gdpr_require_explicit_choice
    end
  end
end
