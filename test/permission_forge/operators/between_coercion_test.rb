require 'test_helper'

module PermissionForge
  module Operators
    class BetweenCoercionTest < ActiveSupport::TestCase
      test 'coerces two integer strings to integers' do
        result = Registry.send(:coerce_between_values, '5', '50')
        assert_equal [5, 50], result
      end

      test 'coerces two float strings to floats' do
        result = Registry.send(:coerce_between_values, '5.5', '50.5')
        assert_equal [5.5, 50.5], result
      end

      test 'coerces two date strings to dates' do
        result = Registry.send(:coerce_between_values, '2025-01-01', '2025-12-31')
        assert_equal [Date.new(2025, 1, 1), Date.new(2025, 12, 31)], result
      end

      test 'leaves two plain strings as strings' do
        result = Registry.send(:coerce_between_values, 'alpha', 'zeta')
        assert_equal %w[alpha zeta], result
      end

      test 'leaves mixed types as strings (no partial coercion)' do
        result = Registry.send(:coerce_between_values, '5', 'abc')
        assert_equal %w[5 abc], result
      end

      test 'coerces negative numbers correctly' do
        result = Registry.send(:coerce_between_values, '-10', '10')
        assert_equal [-10, 10], result
      end

      test 'coerces zero correctly' do
        result = Registry.send(:coerce_between_values, '0', '100')
        assert_equal [0, 100], result
      end

      # Integration test with actual between query
      test 'between rule on numeric column with string values returns correct results' do
        user = create_user
        permission_set = create_permission_set
        create_permission_set_user(user: user, permission_set: permission_set)
        resource = create_resource(
          permission_set: permission_set,
          name: 'Customer',
          read_access: true
        )
        create_permission_set_rule(
          permission_set: permission_set,
          resource: resource,
          field_name: 'id',
          field_value: '1,999999',
          operator: 'between'
        )
        user.regenerate_permissions
        Current.user = user

        customer = create_customer(name: 'Test')
        found = Customer.find_by(id: customer.id)
        assert_equal customer.id, found.id
      end

      # Verify existing between behavior still works with strings
      test 'between with string values still works' do
        result = Registry.send(:coerce_between_values, 'A', 'Z')
        assert_equal %w[A Z], result
      end
    end
  end
end
