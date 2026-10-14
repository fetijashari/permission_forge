require 'test_helper'

module PermissionForge
  module Concerns
    class MaskedAttributesTest < ActiveSupport::TestCase
      # Subclass Customer so we don't pollute other tests that rely on
      # Customer attributes being unfiltered.
      class GuardedCustomer < ::Customer
        include PermissionForge::Concerns::MaskedAttributes

        # The concern resolves the resource name via self.class.name.to_sym.
        # Anonymous/internal subclasses need to declare which resource they map to.
        def self.name
          'Customer'
        end
      end

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
          resource: @resource, name: 'domain', label: 'Domain',
          read_access: false
        )
        @user.regenerate_permissions
        Current.user = @user

        PermissionForge.configuration.unconfigured_field_strategy = :pass_through

        @customer = GuardedCustomer.create!(
          uuid: SecureRandom.uuid,
          name: 'Acme Corp',
          email: 'contact@acme.com',
          domain: 'acme.com'
        )
      end

      test 'direct getter returns raw value for fields with read access' do
        assert_equal 'Acme Corp', @customer.name
      end

      test 'direct getter returns masked value for fields with mask_access' do
        assert_equal 'c***@acme.com', @customer.email
      end

      test 'direct getter returns hidden_attribute_value when read denied' do
        assert_nil @customer.domain
      end

      test 'direct getter applies full mask strategy' do
        # Add a name mask after the fact, regenerate, and verify customer.name is masked
        name_field = PermissionForge::ResourceField.find_by(resource: @resource, name: 'name')
        name_field.update!(mask_access: true, mask_strategy: 'full')
        @user.regenerate_permissions
        assert_equal '*' * 8, @customer.name
      end

      test 'read_attribute returns raw value for fields with read access' do
        assert_equal 'Acme Corp', @customer.read_attribute(:name)
      end

      test 'read_attribute returns masked value for fields with mask_access' do
        assert_equal 'c***@acme.com', @customer.read_attribute(:email)
      end

      test 'read_attribute returns hidden_attribute_value when read denied' do
        assert_nil @customer.read_attribute(:domain)
      end

      test 'read_attribute uses configured sentinel when read denied' do
        sentinel = Object.new
        PermissionForge.configuration.hidden_attribute_value = sentinel
        assert_equal sentinel, @customer.read_attribute(:domain)
      ensure
        PermissionForge.configuration.hidden_attribute_value = nil
      end

      test 'attributes hash omits hidden keys by default' do
        attrs = @customer.attributes
        refute attrs.key?('domain')
        assert_equal 'Acme Corp', attrs['name']
        assert_equal 'c***@acme.com', attrs['email']
      end

      test 'as_json omits hidden keys by default' do
        json = @customer.as_json
        refute json.key?('domain')
        assert_equal 'c***@acme.com', json['email']
      end

      test 'attributes hash includes hidden keys with sentinel when omit disabled' do
        PermissionForge.configuration.omit_hidden_in_attributes_hash = false
        attrs = @customer.attributes
        assert attrs.key?('domain')
        assert_nil attrs['domain']
      ensure
        PermissionForge.configuration.omit_hidden_in_attributes_hash = true
      end

      test 'bypasses enforcement when current_user is nil' do
        Current.user = nil
        assert_equal 'acme.com', @customer.read_attribute(:domain)
        assert_equal 'contact@acme.com', @customer.read_attribute(:email)
      end

      test 'unconfigured fields pass through under pass_through strategy' do
        # supplier_id has no ResourceField — pass_through should leave it alone
        assert_nil @customer.read_attribute(:supplier_id)
      end

      test 'unconfigured fields are blocked under :block strategy' do
        PermissionForge.configuration.unconfigured_field_strategy = :block
        attrs = @customer.attributes
        # supplier_id and account_id and uuid have no ResourceField — should be omitted
        refute attrs.key?('supplier_id')
        refute attrs.key?('account_id')
      end

      test 'masking and filtering survive a JSON round-trip' do
        json = JSON.parse(@customer.to_json)
        refute json.key?('domain')
        assert_equal 'c***@acme.com', json['email']
        assert_equal 'Acme Corp', json['name']
      end
    end
  end
end
