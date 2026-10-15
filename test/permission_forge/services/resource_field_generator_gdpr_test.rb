require 'test_helper'

module PermissionForge
  module Services
    class ResourceFieldGeneratorGdprTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      # Full access is what grant_all asks for: no mask, the recommended
      # strategy kept for when someone masks the field later.
      test 'grant_all true with gdpr_defaults true leaves the email field unmasked' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        email_field = fields.find { |f| f.name == 'email' }

        assert email_field.read_access
        assert email_field.edit_access
        assert_not email_field.mask_access, 'grant_all asks for full access: no mask'
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

      test 'grant_all true with gdpr_defaults true leaves the name field unmasked, first1_last4 recommended' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        name_field = fields.find { |f| f.name == 'name' }

        assert_not name_field.mask_access
        assert name_field.edit_access
        assert_equal 'first1_last4', name_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all true with gdpr_defaults true: the auditor still reports the unmasked personal fields' do
        PermissionForge.configuration.gdpr_defaults = true

        ResourceFieldGenerator.call(resource: @resource, grant_all: true)
        reported = GdprFieldAuditor.call.select { |f| f[:type] == :unmasked_field && f[:resource_name] == 'Customer' }

        assert_includes reported.map { |f| f[:field_name] }, 'email'
        assert_includes reported.map { |f| f[:field_name] }, 'name'
        assert_equal 'email', reported.find { |f| f[:field_name] == 'email' }[:suggested_strategy]
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'grant_all false with gdpr_defaults true masks the name field, as before' do
        PermissionForge.configuration.gdpr_defaults = true

        fields = ResourceFieldGenerator.call(resource: @resource, grant_all: false)
        name_field = fields.find { |f| f.name == 'name' }

        assert name_field.read_access
        assert_not name_field.edit_access
        assert name_field.mask_access
        assert_equal 'first1_last4', name_field.mask_strategy
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end
    end
  end
end
