require 'test_helper'

module PermissionForge
  class ConfigurationFilterParametersTest < ActiveSupport::TestCase
    setup do
      @config = PermissionForge::Configuration.new
      @original_config = PermissionForge.configuration
    end

    teardown do
      PermissionForge.instance_variable_set(:@configuration, @original_config)
    end

    # --- Config defaults ---

    test 'filter_parameters_integration defaults to true' do
      assert_equal true, @config.filter_parameters_integration
    end

    test 'filter_parameters_integration can be set to true' do
      @config.filter_parameters_integration = true
      assert @config.filter_parameters_integration
    end

    # --- gdpr_filter_parameters helper ---

    test 'gdpr_filter_parameters returns GDPR pattern regexes when gdpr_defaults is true' do
      @config.gdpr_defaults = true
      PermissionForge.instance_variable_set(:@configuration, @config)

      result = PermissionForge.gdpr_filter_parameters

      assert_kind_of Array, result
      assert(result.all?(Regexp))
      assert_equal @config.gdpr_field_patterns.keys.size, result.size
    end

    test 'gdpr_filter_parameters returns empty array when gdpr_defaults is false' do
      @config.gdpr_defaults = false
      PermissionForge.instance_variable_set(:@configuration, @config)

      result = PermissionForge.gdpr_filter_parameters

      assert_equal [], result
    end

    test 'gdpr_filter_parameters includes patterns that match known PII fields' do
      @config.gdpr_defaults = true
      PermissionForge.instance_variable_set(:@configuration, @config)

      result = PermissionForge.gdpr_filter_parameters

      pii_fields = %w[email phone ssn first_name last_name address date_of_birth iban ip_address]
      pii_fields.each do |field|
        assert result.any? { |regex| field.match?(regex) },
               "Expected gdpr_filter_parameters to include a pattern matching '#{field}'"
      end
    end

    test 'gdpr_filter_parameters reflects custom gdpr_field_patterns' do
      @config.gdpr_defaults = true
      custom_patterns = { /\Acustom_secret\z/ => 'full', /tax_id/ => 'last4' }
      @config.gdpr_field_patterns = custom_patterns
      PermissionForge.instance_variable_set(:@configuration, @config)

      result = PermissionForge.gdpr_filter_parameters

      assert_equal 2, result.size
      assert(result.any? { |regex| 'custom_secret'.match?(regex) })
      assert(result.any? { |regex| 'tax_id'.match?(regex) })
    end

    test 'gdpr_filter_parameters does not include non-PII fields' do
      @config.gdpr_defaults = true
      PermissionForge.instance_variable_set(:@configuration, @config)

      result = PermissionForge.gdpr_filter_parameters

      safe_fields = %w[status is_active created_at quantity description]
      safe_fields.each do |field|
        refute result.any? { |regex| field.match?(regex) },
               "Expected gdpr_filter_parameters NOT to match '#{field}'"
      end
    end
  end
end
