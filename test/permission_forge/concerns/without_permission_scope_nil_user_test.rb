# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Concerns
    # PermissionForge.without_permission_scope is the documented way to run
    # trusted code with nobody signed in (a job, a seed, a webhook, a sign-in
    # lookup). Inside the host's block, find_by, find_by! and permission_scoped
    # apply no rules when there is no current user, whatever nil_user_strategy
    # says — the block is an explicit opt-out in code, while :deny and :raise
    # exist to catch code that forgot to set a user. The bypass is published
    # as rule.bypassed (scope_suspended). A signed-in user's lookups stay
    # checked, and outside the block nothing changes.
    class WithoutPermissionScopeNilUserTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'supplier_id',
                                   field_value: 'current_user', operator: 'equal', include_nulls: false,
                                   name: 'Own customers', failure_message: 'Not yours')
        @theirs = create_customer(supplier_id: @user.id + 999)
        Current.user = nil
      end

      teardown { Current.user = nil }

      %i[deny raise].each do |strategy|
        test "inside the block nobody signed in finds the record under nil_user_strategy :#{strategy}" do
          PermissionForge.configuration.nil_user_strategy = strategy

          PermissionForge.without_permission_scope do
            assert_equal @theirs, Customer.find_by(id: @theirs.id)
            assert_equal @theirs, Customer.find_by!(id: @theirs.id)
            assert_includes Customer.permission_scoped.to_a, @theirs
          end
        end
      end

      test 'outside the block :deny still finds nothing and :raise still raises' do
        PermissionForge.configuration.nil_user_strategy = :deny
        assert_nil Customer.find_by(id: @theirs.id)
        assert_empty Customer.permission_scoped

        PermissionForge.configuration.nil_user_strategy = :raise
        assert_raises(PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: @theirs.id) }
      end

      test 'inside the block a signed-in user is still held to the rules' do
        PermissionForge.configuration.nil_user_strategy = :deny
        @user.regenerate_permissions
        Current.user = @user

        PermissionForge.without_permission_scope do
          assert_raises(PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: @theirs.id) }
          assert_not_includes Customer.permission_scoped.to_a, @theirs
        end
      end

      test 'the bypass is published as rule.bypassed, scope_suspended' do
        PermissionForge.configuration.nil_user_strategy = :deny
        events = []
        callback = ->(*, payload) { events << payload }

        ActiveSupport::Notifications.subscribed(callback, 'rule.bypassed.permission_forge') do
          PermissionForge.without_permission_scope { Customer.find_by(id: @theirs.id) }
        end

        reasons = events.map { |payload| payload.dig(:data, 'reason') || payload[:reason] }
        assert_includes reasons, 'scope_suspended'
        assert_not_includes reasons, 'nil_user'
      end
    end
  end
end
