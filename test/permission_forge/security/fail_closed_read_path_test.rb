require 'test_helper'

module PermissionForge
  module Security
    # Regression tests for the read-path fail-closed posture.
    # An authenticated user with no configured access to a resource must never
    # receive raw attributes; cache misses must not leak plaintext.
    class FailClosedReadPathTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        # NOTE: the user has NO Resource entry for 'Customer' at all.
        @user.regenerate_permissions
        Current.user = @user
        @original_strategy = PermissionForge.configuration.unconfigured_field_strategy
        @original_nil_user = PermissionForge.configuration.response_filter_nil_user_strategy
      end

      teardown do
        PermissionForge.configuration.unconfigured_field_strategy = @original_strategy
        PermissionForge.configuration.response_filter_nil_user_strategy = @original_nil_user
      end

      def filter(attrs)
        Services::FiltersResponseAttributes.call(
          attributes: attrs, resource_name: 'Customer', user: @user
        )
      end

      test 'authenticated user with no resource access gets nothing under :block (fail closed)' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        result = filter(name: 'Acme', email: 'a@b.com', ssn: '123456789')
        assert_empty result
      end

      test 'authenticated user with no resource access gets fully masked under :mask_all' do
        PermissionForge.configuration.unconfigured_field_strategy = :mask_all
        result = filter(email: 'a@b.com')
        assert_equal '********', result[:email]
      end

      test 'unknown unconfigured strategy falls back to :block, not pass-through' do
        PermissionForge.configuration.unconfigured_field_strategy = :nonsense_value
        result = filter(name: 'Acme', email: 'a@b.com')
        assert_empty result
      end

      test 'nil user returns raw under :bypass (default, backward compatible)' do
        Current.user = nil
        PermissionForge.configuration.response_filter_nil_user_strategy = :bypass
        result = Services::FiltersResponseAttributes.call(
          attributes: { name: 'Acme' }, resource_name: 'Customer', user: nil
        )
        assert_equal({ name: 'Acme' }, result)
      end

      test 'nil user returns nothing under :block (strict fail closed)' do
        Current.user = nil
        PermissionForge.configuration.response_filter_nil_user_strategy = :block
        result = Services::FiltersResponseAttributes.call(
          attributes: { name: 'Acme' }, resource_name: 'Customer', user: nil
        )
        assert_empty result
      end

      test 'masked_field? reports unconfigured field as masked under :block (fail closed)' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        assert @user.masked_field?(:Customer, :email)
      end

      test 'masked_field? reports unconfigured field as unmasked under :pass_through' do
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        assert_not @user.masked_field?(:Customer, :email)
      end

      test 'AttributeAccessGuard falls back to block for unknown strategy' do
        PermissionForge.configuration.unconfigured_field_strategy = :nonsense_value
        include_field, = Services::AttributeAccessGuard.call(
          resource_name: :Customer, attribute: :email, raw_value: 'a@b.com', user: @user
        )
        assert_not include_field
      end
    end
  end
end
