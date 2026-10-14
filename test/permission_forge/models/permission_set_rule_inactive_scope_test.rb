require 'test_helper'

module PermissionForge
  class PermissionSetRuleInactiveScopeTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    end

    test 'rule deactivated 3 days ago is in recently_deactivated scope' do
      rule = create_permission_set_rule(
        permission_set: @permission_set, resource: @resource, is_active: false
      )
      rule.update_column(:updated_at, 3.days.ago)

      assert_includes PermissionForge::PermissionSetRule.recently_deactivated, rule
    end

    test 'rule deactivated 10 days ago is not in recently_deactivated scope' do
      rule = create_permission_set_rule(
        permission_set: @permission_set, resource: @resource, is_active: false
      )
      rule.update_column(:updated_at, 10.days.ago)

      assert_not_includes PermissionForge::PermissionSetRule.recently_deactivated, rule
    end

    test 'active rule is not in recently_deactivated scope' do
      rule = create_permission_set_rule(
        permission_set: @permission_set, resource: @resource, is_active: true
      )

      assert_not_includes PermissionForge::PermissionSetRule.recently_deactivated, rule
    end
  end
end
