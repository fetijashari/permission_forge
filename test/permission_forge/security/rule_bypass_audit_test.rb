# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    class RuleBypassAuditTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(
          permission_set: @permission_set,
          name: 'Customer',
          read_access: true,
          view_all: true
        )
        create_permission_set_rule(
          permission_set: @permission_set,
          resource: @resource,
          field_name: 'supplier_id',
          field_value: 'current_user',
          operator: 'equal'
        )
        @customer = create_customer(supplier_id: @user.id + 999)
        @user.regenerate_permissions
        Current.user = @user
      end

      teardown do
        PermissionForge.configuration.on_rule_bypass = nil
      end

      test 'on_rule_bypass callback fires when view_all bypasses rules' do
        called = false
        received = {}
        PermissionForge.configuration.on_rule_bypass = lambda { |user:, resource:, reason:|
          called = true
          received[:user] = user
          received[:resource] = resource
          received[:reason] = reason
        }

        Customer.find_by(uuid: @customer.uuid)

        assert called, 'on_rule_bypass should have been called'
        assert_equal @user, received[:user]
        assert_equal 'Customer', received[:resource]
        assert_equal :view_all_or_modify_all, received[:reason]
      end

      test 'on_rule_bypass callback does not fire when no bypass' do
        @resource.update!(view_all: false)
        @user.regenerate_permissions
        Current.user = @user

        called = false
        PermissionForge.configuration.on_rule_bypass = ->(**) { called = true }

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by(uuid: @customer.uuid)
        end
        assert_not called, 'on_rule_bypass should not fire without bypass'
      end

      test 'on_rule_bypass callback errors are swallowed' do
        PermissionForge.configuration.on_rule_bypass = ->(**) { raise 'boom' }

        # Should not raise — error is swallowed
        result = Customer.find_by(uuid: @customer.uuid)
        assert_equal @customer, result
      end

      test 'on_rule_bypass callback not called when hook is nil' do
        PermissionForge.configuration.on_rule_bypass = nil
        # Should not raise
        assert_equal @customer, Customer.find_by(uuid: @customer.uuid)
      end
    end
  end
end
