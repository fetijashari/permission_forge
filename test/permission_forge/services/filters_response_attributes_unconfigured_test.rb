require 'test_helper'

module PermissionForge
  module Services
    class FiltersResponseAttributesUnconfiguredTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true
        )
        create_resource_field(
          resource: @resource, name: 'name', label: 'Name',
          read_access: true, edit_access: true
        )
        create_resource_field(
          resource: @resource, name: 'secret', label: 'Secret',
          read_access: false, edit_access: false
        )
        create_resource_field(
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'email'
        )
        @user.regenerate_permissions
        Current.user = @user
        @original_strategy = PermissionForge.configuration.unconfigured_field_strategy
      end

      teardown do
        PermissionForge.configuration.unconfigured_field_strategy = @original_strategy
      end

      # --- :pass_through ---

      test 'pass_through strategy passes unconfigured field through unmasked' do
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        result = filter(name: 'Acme', domain: 'acme.com')
        assert_equal 'Acme', result[:name]
        assert_equal 'acme.com', result[:domain]
      end

      # --- :warn ---

      test 'warn strategy passes unconfigured field through and logs warning' do
        PermissionForge.configuration.unconfigured_field_strategy = :warn
        log_output = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log_output)

        result = filter(name: 'Acme', domain: 'acme.com')
        assert_equal 'acme.com', result[:domain]
        assert_match(/unconfigured field.*domain.*Customer/i, log_output.string)
      ensure
        Rails.logger = original_logger
      end

      # --- :mask_all ---

      test 'mask_all strategy masks unconfigured field with full strategy' do
        PermissionForge.configuration.unconfigured_field_strategy = :mask_all
        result = filter(name: 'Acme', domain: 'acme.com')
        assert_equal 'Acme', result[:name]
        assert_equal '********', result[:domain]
      end

      # --- :block ---

      test 'block strategy excludes unconfigured field from result' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        result = filter(name: 'Acme', domain: 'acme.com')
        assert_equal 'Acme', result[:name]
        assert_not result.key?(:domain)
      end

      # --- configured fields unaffected ---

      test 'configured fields behave identically regardless of strategy' do
        %i[pass_through warn mask_all block].each do |strategy|
          PermissionForge.configuration.unconfigured_field_strategy = strategy

          result = filter(name: 'Acme', secret: 'hidden', email: 'john@example.com')
          assert_equal 'Acme', result[:name], "Failed for strategy #{strategy}"
          assert_not result.key?(:secret), "Secret should be hidden for strategy #{strategy}"
          assert_equal 'j***@example.com', result[:email], "Email should be masked for strategy #{strategy}"
        end
      end

      # --- edge cases ---

      test 'empty attributes hash returns empty result regardless of strategy' do
        %i[pass_through warn mask_all block].each do |strategy|
          PermissionForge.configuration.unconfigured_field_strategy = strategy
          result = filter({})
          assert_equal({}, result)
        end
      end

      test 'multiple unconfigured fields each handled by strategy' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        result = filter(name: 'Acme', domain: 'acme.com', supplier_id: 42)
        assert_equal 'Acme', result[:name]
        assert_not result.key?(:domain)
        assert_not result.key?(:supplier_id)
      end

      private

      def filter(attributes)
        FiltersResponseAttributes.call(
          attributes: attributes,
          resource_name: 'Customer',
          user: @user
        )
      end
    end
  end
end
