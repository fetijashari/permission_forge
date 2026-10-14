require 'test_helper'

module PermissionForge
  module Services
    class AttributeAccessGuardTest < ActiveSupport::TestCase
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
          read_access: true, mask_access: true, mask_strategy: 'email'
        )
        create_resource_field(
          resource: @resource, name: 'secret', label: 'Secret',
          read_access: false
        )
        @user.regenerate_permissions
      end

      test 'returns raw value when user has read access without mask' do
        include_field, value = call(:name, 'Acme')
        assert include_field
        assert_equal 'Acme', value
      end

      test 'returns masked value when mask_access is true' do
        include_field, value = call(:email, 'john@example.com')
        assert include_field
        assert_equal 'j***@example.com', value
      end

      test 'returns false-include and hidden value when read_access is false' do
        include_field, value = call(:secret, 'classified')
        refute include_field
        assert_nil value
      end

      test 'uses configured hidden_attribute_value when read denied' do
        sentinel = Object.new
        PermissionForge.configuration.hidden_attribute_value = sentinel
        _, value = call(:secret, 'classified')
        assert_equal sentinel, value
      ensure
        PermissionForge.configuration.hidden_attribute_value = nil
      end

      test 'bypasses guard when no user is provided and resolver returns nil' do
        Current.user = nil
        include_field, value = PermissionForge::Services::AttributeAccessGuard.call(
          resource_name: :Customer, attribute: :secret, raw_value: 'classified', user: nil
        )
        assert include_field
        assert_equal 'classified', value
      end

      test 'applies unconfigured field strategy for unmapped attributes' do
        PermissionForge.configuration.unconfigured_field_strategy = :pass_through
        include_field, value = call(:domain, 'acme.com')
        assert include_field
        assert_equal 'acme.com', value
      end

      test 'block strategy excludes unconfigured attributes' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        include_field, value = call(:domain, 'acme.com')
        refute include_field
        assert_nil value
      end

      test 'mask_all strategy masks unconfigured attributes' do
        PermissionForge.configuration.unconfigured_field_strategy = :mask_all
        include_field, value = call(:domain, 'acme.com')
        assert include_field
        assert_equal '*' * 8, value
      end

      test 'invokes on_field_filtered hook with action symbol' do
        events = []
        PermissionForge.configuration.on_field_filtered = lambda { |args|
          events << args[:action]
        }
        call(:name, 'Acme')
        call(:email, 'john@example.com')
        call(:secret, 'classified')
        assert_includes events, :passed
        assert_includes events, :masked
        assert_includes events, :hidden
      ensure
        PermissionForge.configuration.on_field_filtered = nil
      end

      test 'swallows hook errors' do
        PermissionForge.configuration.on_field_filtered = ->(_args) { raise 'boom' }
        assert_nothing_raised { call(:name, 'Acme') }
      ensure
        PermissionForge.configuration.on_field_filtered = nil
      end

      # resource_name: may be the chain of names a class answers to
      # (ResourceChain): the field is looked up along it, strictest entry wins,
      # and the decision is reported under the first name.
      test 'a chain of resource names is looked up along, the strictest entry deciding' do
        fields = { Sub: { email: { read_access: true, edit_access: true, mask_access: false, mask_strategy: 'full' } },
                   Base: { email: { read_access: true, edit_access: false, mask_access: true, mask_strategy: 'email' } } }
        user = Object.new
        user.define_singleton_method(:field_permissions) { |resource, field| fields.dig(resource, field) }
        seen = []
        PermissionForge.configuration.on_field_filtered = ->(args) { seen << args }

        include_field, value = PermissionForge::Services::AttributeAccessGuard.call(
          resource_name: %i[Sub Base], attribute: :email, raw_value: 'john@example.com', user: user
        )

        assert include_field
        assert_equal 'j***@example.com', value
        assert_equal 'j***@example.com', PermissionForge::Services::AttributeAccessGuard.call(
          resource_name: %i[Base Sub], attribute: :email, raw_value: 'john@example.com', user: user
        ).last
        assert_equal 'john@example.com', PermissionForge::Services::AttributeAccessGuard.call(
          resource_name: [:Sub], attribute: :email, raw_value: 'john@example.com', user: user
        ).last
        assert_equal ['Sub', :masked], seen.first.values_at(:resource_name, :action), 'reported under the first name'
      ensure
        PermissionForge.configuration.on_field_filtered = nil
      end

      private

      def call(attribute, value)
        PermissionForge::Services::AttributeAccessGuard.call(
          resource_name: :Customer, attribute: attribute, raw_value: value, user: @user
        )
      end
    end
  end
end
