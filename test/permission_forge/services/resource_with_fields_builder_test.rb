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
          assert_equal %w[created_at updated_at].exclude?(field.name), field.edit_access, "#{field.name} edit_access (timestamps are read-only)"
        end
      end

      test 'masks nothing, also under gdpr_defaults: the caller asked for full access' do
        PermissionForge.configuration.gdpr_defaults = true
        resource = ResourceWithFieldsBuilder.call(permission_set: create_permission_set, resource_name: 'Customer')

        assert_equal [], resource.resource_fields.select(&:mask_access).map(&:name)
        assert_equal 'email', resource.resource_fields.find_by!(name: 'email').mask_strategy
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
