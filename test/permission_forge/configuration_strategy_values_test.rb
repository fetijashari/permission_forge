require 'test_helper'

module PermissionForge
  # The strategy options that decide whether something is allowed take a
  # Symbol, accept its String, and refuse anything else at assignment time.
  # A String used to be read as an unknown value: for
  # response_filter_nil_user_strategy, 'block' meant :bypass.
  class ConfigurationStrategyValuesTest < ActiveSupport::TestCase
    OPTIONS = {
      nil_user_strategy: %i[bypass raise deny],
      no_read_access_strategy: %i[rules_only deny],
      response_filter_nil_user_strategy: %i[bypass block],
      masked_write_protection: %i[skip raise off],
      masked_attributes_nil_user_strategy: %i[bypass hide_in_requests hide],
      action_guard_nil_user_strategy: %i[bypass deny raise],
      admin_tenantless_access: %i[deny allow],
      unconfigured_action_strategy: %i[allow block],
      extra_fields_default_access: %i[grant unconfigured]
    }.freeze

    setup { @config = PermissionForge::Configuration.new }

    OPTIONS.each do |option, allowed|
      test "#{option} takes each allowed Symbol and its String" do
        allowed.each do |value|
          @config.public_send(:"#{option}=", value)
          assert_equal value, @config.public_send(option)

          @config.public_send(:"#{option}=", value.to_s)
          assert_equal value, @config.public_send(option), "#{value.to_s.inspect} is taken as #{value.inspect}"
        end
      end

      test "#{option} refuses an unknown value" do
        error = assert_raises(PermissionForge::ConfigurationError) { @config.public_send(:"#{option}=", :sometimes) }
        assert_match(/#{option}/, error.message)
        assert_raises(PermissionForge::ConfigurationError) { @config.public_send(:"#{option}=", 42) }
      end
    end

    test "response_filter_nil_user_strategy 'block' now blocks" do
      PermissionForge.configuration.response_filter_nil_user_strategy = 'block'
      original = PermissionForge.configuration.current_user_resolver
      PermissionForge.configuration.current_user_resolver = -> {}

      filtered = PermissionForge::Services::FiltersResponseAttributes.call(attributes: { 'email' => 'a@b.c' },
                                                                           resource_name: 'Customer')
      assert_empty filtered
    ensure
      PermissionForge.configuration.response_filter_nil_user_strategy = :bypass
      PermissionForge.configuration.current_user_resolver = original
    end

    test 'action_guard_nil_user_strategy nil or blank follows nil_user_strategy' do
      [nil, ''].each do |value|
        @config.action_guard_nil_user_strategy = value
        assert_nil @config.action_guard_nil_user_strategy
      end
    end
  end
end
