require 'test_helper'

module PermissionForge
  module Services
    class FiltersResponseAttributesTest < ActiveSupport::TestCase
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
          resource: @resource, name: 'email', label: 'Email',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: @resource, name: 'phone', label: 'Phone',
          read_access: true, edit_access: false,
          mask_access: true, mask_strategy: 'last4'
        )
        create_resource_field(
          resource: @resource, name: 'secret', label: 'Secret',
          read_access: false, edit_access: false
        )
        @user.regenerate_permissions
        Current.user = @user
      end

      test 'removes fields without read_access' do
        result = filter(name: 'Acme', secret: 'hidden')
        assert_equal({ name: 'Acme' }, result)
      end

      test 'keeps fields with read_access' do
        result = filter(name: 'Acme')
        assert_equal({ name: 'Acme' }, result)
      end

      test 'masks fields with mask_access using email strategy' do
        result = filter(email: 'john@example.com')
        assert_equal 'j***@example.com', result[:email]
      end

      test 'masks fields with mask_access using last4 strategy' do
        result = filter(phone: '+1234567890')
        assert_equal '*******7890', result[:phone]
      end

      test 'does not mask fields without mask_access' do
        result = filter(name: 'Acme Corp')
        assert_equal 'Acme Corp', result[:name]
      end

      test 'passes through fields not in permissions (unconfigured)' do
        result = filter(name: 'Acme', domain: 'acme.com')
        assert_equal 'Acme', result[:name]
        assert_equal 'acme.com', result[:domain]
      end

      test 'filters and masks in a single pass' do
        result = filter(name: 'Acme', email: 'john@example.com', secret: 'hidden', domain: 'acme.com')
        assert_equal 'Acme', result[:name]
        assert_equal 'j***@example.com', result[:email]
        assert_nil result[:secret]
        assert_not result.key?(:secret)
        assert_equal 'acme.com', result[:domain]
      end

      test 'returns original hash when no user' do
        Current.user = nil
        attrs = { name: 'Acme', secret: 'hidden' }
        result = PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: attrs, resource_name: 'Customer', user: nil
        )
        assert_equal attrs, result
      end

      test 'returns original hash when no permissions configured' do
        attrs = { name: 'Acme' }
        result = PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: attrs, resource_name: 'UnknownModel', user: @user
        )
        assert_equal attrs, result
      end

      test 'handles nil values gracefully with masking' do
        result = filter(email: nil)
        assert_nil result[:email]
      end

      test 'handles blank string values with masking' do
        result = filter(email: '')
        assert_equal '', result[:email]
      end

      test 'works with string keys' do
        result = PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: { 'name' => 'Acme', 'secret' => 'hidden', 'email' => 'john@example.com' },
          resource_name: 'Customer',
          user: @user
        )
        assert_equal 'Acme', result['name']
        assert_not result.key?('secret')
        assert_equal 'j***@example.com', result['email']
      end

      test 'does not mutate the original hash' do
        original = { name: 'Acme', secret: 'hidden' }
        frozen_copy = original.dup
        filter(name: 'Acme', secret: 'hidden')
        assert_equal frozen_copy, original
      end

      test 'returns empty-like hash when all fields lack read_access' do
        result = filter(secret: 'hidden')
        assert_equal({}, result)
      end

      test 'accepts explicit user parameter' do
        Current.user = nil
        result = PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: { name: 'Acme', secret: 'hidden' },
          resource_name: 'Customer',
          user: @user
        )
        assert_equal({ name: 'Acme' }, result)
      end

      private

      def filter(attributes)
        PermissionForge::Services::FiltersResponseAttributes.call(
          attributes: attributes,
          resource_name: 'Customer',
          user: @user
        )
      end
    end
  end
end
