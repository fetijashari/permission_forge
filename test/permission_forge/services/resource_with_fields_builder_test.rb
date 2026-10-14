require 'test_helper'

module PermissionForge
  module Services
    class ResourceWithFieldsBuilderTest < ActiveSupport::TestCase
      test 'creates resource with full CRUD access' do
        ps = create_permission_set

        resource = ResourceWithFieldsBuilder.call(permission_set: ps, resource_name: 'Customer')

        assert resource.persisted?
        assert_equal 'Customer', resource.name
        assert resource.read_access
        assert resource.create_access
        assert resource.edit_access
        assert resource.delete_access
        assert resource.is_active
      end

      test 'generates resource fields with grant_all' do
        ps = create_permission_set

        resource = ResourceWithFieldsBuilder.call(permission_set: ps, resource_name: 'Customer')

        assert resource.resource_fields.any?
        resource.resource_fields.each do |field|
          assert field.read_access, "Expected #{field.name} to have read_access"
          assert field.edit_access, "Expected #{field.name} to have edit_access"
        end
      end

      test 'associates resource with the given permission set' do
        ps = create_permission_set

        resource = ResourceWithFieldsBuilder.call(permission_set: ps, resource_name: 'Order')

        assert_equal ps.id, resource.permission_set_id
      end

      test 'returns the created resource' do
        ps = create_permission_set

        result = ResourceWithFieldsBuilder.call(permission_set: ps, resource_name: 'Product')

        assert_instance_of PermissionForge::Resource, result
        assert result.persisted?
      end
    end
  end
end
