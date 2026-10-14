# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class RuleApplierNilGuardTest < ActiveSupport::TestCase
      test 'raises ArgumentError when current_user is nil and rule uses current_user substitution' do
        rules = [{ field_name: 'user_id', field_value: 'current_user', operator: 'equal',
                   include_nulls: false, name: 'Test', failure_message: 'Denied' }]

        error = assert_raises(ArgumentError) do
          PermissionForge::Services::PermissionRuleApplier.call(
            model_class: Customer,
            rules: rules,
            args: [{ uuid: 'test' }],
            current_user: nil
          )
        end
        assert_match(/current_user is nil/, error.message)
      end

      test 'does not raise when current_user is present and rule uses current_user substitution' do
        user = create_user
        customer = create_customer(supplier_id: user.id)
        ps = create_permission_set
        create_permission_set_user(user: user, permission_set: ps)
        resource = create_resource(permission_set: ps, name: 'Customer', read_access: true)
        create_permission_set_rule(
          permission_set: ps, resource: resource,
          field_name: 'supplier_id', field_value: 'current_user', operator: 'equal'
        )
        user.regenerate_permissions

        query, failures = PermissionForge::Services::PermissionRuleApplier.call(
          model_class: Customer,
          rules: user.permissions_hash.dig(:permissions, :resources, :Customer, :permission_set_rules),
          args: [{ uuid: customer.uuid }],
          current_user: user
        )

        assert_empty failures
        assert_not_nil query
      end
    end
  end
end
