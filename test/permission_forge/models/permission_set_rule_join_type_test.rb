require 'test_helper'

module PermissionForge
  # One definition of "join rule" for the admin UI, attention items and the
  # boot warning — the same one auto_query_scoping uses to skip a rule.
  class PermissionSetRuleJoinTypeTest < ActiveSupport::TestCase
    setup do
      @set = create_permission_set
      @resource = create_resource(permission_set: @set)
    end

    test 'rules without a join type are filter rules' do
      rule = create_permission_set_rule(permission_set: @set, resource: @resource)

      assert_not rule.join_rule?
      assert_empty PermissionSetRule.join_type_rules
    end

    test 'any join type makes a join rule, even without a relationship path' do
      joined = create_permission_set_rule(permission_set: @set, resource: @resource, join_type: 'joins',
                                          field_accessor_path: 'supplier')
      no_path = create_permission_set_rule(permission_set: @set, resource: @resource, join_type: 'left_joins')

      assert joined.join_rule?
      assert no_path.join_rule?
      assert_equal [joined, no_path].sort_by(&:id), PermissionSetRule.join_type_rules.order(:id).to_a
    end
  end
end
