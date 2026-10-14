require 'test_helper'

module PermissionForge
  module Services
    class ResourceFieldGeneratorTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
      end

      test 'generates fields from model columns' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        field_names = fields.map(&:name)

        assert_includes field_names, 'name'
        assert_includes field_names, 'email'
        assert_includes field_names, 'domain'
        assert_includes field_names, 'supplier_id'
      end

      test 'excludes ignored fields' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        field_names = fields.map(&:name)

        assert_not_includes field_names, 'id'
        assert_not_includes field_names, 'created_at'
        assert_not_includes field_names, 'updated_at'
        assert_not_includes field_names, 'uuid'
      end

      test 'sets read_access and edit_access to false by default' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        fields.each do |field|
          assert_not field.read_access, "Expected #{field.name} read_access to be false"
          assert_not field.edit_access, "Expected #{field.name} edit_access to be false"
        end
      end

      test 'grants all access when grant_all is true' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource, grant_all: true)

        fields.each do |field|
          assert field.read_access, "Expected #{field.name} read_access to be true"
          assert field.edit_access, "Expected #{field.name} edit_access to be true"
        end
      end

      test 'returns empty array when resource name is not a valid class' do
        invalid_resource = create_resource(permission_set: @permission_set, name: 'NonexistentModel')
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: invalid_resource)
        assert_equal [], fields
      end

      test 'humanizes column names for labels' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        name_field = fields.find { |f| f.name == 'name' }
        assert_equal 'Name', name_field.label
      end

      test 'persists fields to the database' do
        expected_count = Customer.column_names.size -
                         PermissionForge.configuration.ignored_fields.count { |f| Customer.column_names.include?(f) }
        assert_difference 'PermissionForge::ResourceField.count', expected_count do
          PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        end
      end

      # --- GDPR defaults ---

      test 'does not apply GDPR masks when gdpr_defaults is false' do
        PermissionForge.configuration.gdpr_defaults = false
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        email_field = fields.find { |f| f.name == 'email' }
        assert_not email_field.mask_access
      end

      test 'applies GDPR masks when gdpr_defaults is true' do
        PermissionForge.configuration.gdpr_defaults = true
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        email_field = fields.find { |f| f.name == 'email' }
        assert email_field.mask_access
        assert_equal 'email', email_field.mask_strategy

        name_field = fields.find { |f| f.name == 'name' }
        assert name_field.mask_access
        assert_equal 'first1_last4', name_field.mask_strategy

        domain_field = fields.find { |f| f.name == 'domain' }
        assert_not domain_field.mask_access
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end

      test 'respects custom gdpr_field_patterns' do
        PermissionForge.configuration.gdpr_defaults = true
        original = PermissionForge.configuration.gdpr_field_patterns
        PermissionForge.configuration.gdpr_field_patterns = { /domain/ => 'full' }

        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        domain_field = fields.find { |f| f.name == 'domain' }
        assert domain_field.mask_access
        assert_equal 'full', domain_field.mask_strategy

        email_field = fields.find { |f| f.name == 'email' }
        assert_not email_field.mask_access
      ensure
        PermissionForge.configuration.gdpr_defaults = false
        PermissionForge.configuration.gdpr_field_patterns = original
      end

      # --- Virtual fields ---

      test 'under :grant virtual fields get no row, so the implicit grant stays' do
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)

        assert_empty fields.map(&:name) & %w[full_address contact_count]
      end

      test 'under :unconfigured virtual fields get a row like columns do' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        virtual = fields.select { |f| %w[full_address contact_count].include?(f.name) }

        assert_equal %w[contact_count full_address], virtual.map(&:name).sort
        assert(virtual.none? { |f| f.read_access || f.edit_access })
        assert_equal 'Full address', virtual.find { |f| f.name == 'full_address' }.label
      end

      test 'under :unconfigured grant_all keeps full access to virtual fields explicit' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        resource = PermissionForge::Services::ResourceWithFieldsBuilder.call(
          permission_set: create_permission_set, resource_name: 'Customer'
        )
        virtual = resource.resource_fields.find_by(name: 'full_address')

        assert virtual.read_access
        assert virtual.edit_access
      end

      test 'under :unconfigured virtual fields are generated once and get GDPR masks' do
        PermissionForge.configuration.extra_fields_default_access = :unconfigured
        PermissionForge.configuration.gdpr_defaults = true
        fields = PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
        address = fields.find { |f| f.name == 'full_address' }

        assert address.mask_access
        assert_equal 'full', address.mask_strategy
        assert_empty PermissionForge::Services::ResourceFieldGenerator.call(resource: @resource)
      ensure
        PermissionForge.configuration.gdpr_defaults = false
      end
    end
  end
end
