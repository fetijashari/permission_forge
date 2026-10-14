require 'test_helper'

module PermissionForge
  module Services
    class ResourceFieldGeneratorGdprTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'grant_all true with gdpr_defaults true masks email field' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access
        assert email_field.edit_access
        assert email_field.mask_access, 'Expected email field to be masked even with grant_all'
        assert_equal 'email', email_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true does not mask non-PII fields' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        domain_field = fields.find { |f| f.name == 'domain' }

        assert domain_field.read_access
        assert domain_field.edit_access
        assert_not domain_field.mask_access
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults false does not mask email field' do
        PermissionForge.configuration.gdpr_defaults = false

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access
        assert email_field.edit_access
        assert_not email_field.mask_access
      end

      test 'grant_all false with gdpr_defaults true masks GDPR fields' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: false)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access, 'GDPR defaults force read_access true for matched fields'
        assert_not email_field.edit_access
        assert email_field.mask_access
        assert_equal 'email', email_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true masks name field with first1_last4' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        name_field = fields.find { |f| f.name == 'name' }

        assert name_field.mask_access
        assert_equal 'first1_last4', name_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end
    end
  end
end
