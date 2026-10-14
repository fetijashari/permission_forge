require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # Row isolation across all 8 permission models under acts_as_tenant: rows
    # are stamped with the current tenant, invisible from every other tenant,
    # cannot reference another tenant's records, and copies stay in-tenant.
    # Services that read the permission tables inherit the same scope.
    class TenantIsolationTest < ActiveSupport::TestCase
      include TenancyTestHelper

      MODEL_FOR = {
        group: PermissionForge::PermissionSetGroup,
        set: PermissionForge::PermissionSet,
        resource: PermissionForge::Resource,
        field: PermissionForge::ResourceField,
        action: PermissionForge::ResourceAction,
        rule: PermissionForge::PermissionSetRule,
        assignment: PermissionForge::PermissionSetUser,
        membership: PermissionForge::PermissionSetGroupUser
      }.freeze

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user
      end

      # --- stamping and visibility --------------------------------------------

      test 'every permission model is stamped with the current tenant on create' do
        graph = within(@tenant_a) { build_graph('A') }

        graph.each do |kind, record|
          assert_equal @tenant_a.id, record.account_id, "#{kind} should carry tenant A"
        end
      end

      test 'every permission model shows only the current tenant rows' do
        graph_a = within(@tenant_a) { build_graph('A') }
        graph_b = within(@tenant_b) { build_graph('B') }

        MODEL_FOR.each do |kind, model|
          within(@tenant_a) { assert_equal [graph_a[kind].id], model.pluck(:id), "#{kind} under tenant A" }
          within(@tenant_b) { assert_equal [graph_b[kind].id], model.pluck(:id), "#{kind} under tenant B" }
        end
      end

      test 'associations traversed from a tenant row stay inside the tenant' do
        graph_a = within(@tenant_a) { build_graph('A') }
        within(@tenant_b) { build_graph('B') }

        within(@tenant_a) do
          assert_equal [graph_a[:resource].id], graph_a[:set].resources.pluck(:id)
          assert_equal [graph_a[:assignment].id], @user.permission_set_users.pluck(:id)
          assert_equal [graph_a[:set].id], @user.permission_sets.pluck(:id)
          assert_equal [graph_a[:group].id], @user.permission_set_groups.pluck(:id)
        end
      end

      test 'legacy rows with a NULL tenant column are hidden under every tenant' do
        legacy = within(@tenant_a) { create_permission_set(name: 'Legacy') }
        within(@tenant_a) { PermissionForge::PermissionSet.where(id: legacy.id).update_all(account_id: nil) }

        [@tenant_a, @tenant_b].each do |tenant|
          within(tenant) do
            assert_not PermissionForge::PermissionSet.exists?(legacy.id), "hidden under #{tenant.name}"
          end
        end
        no_tenant!
        assert PermissionForge::PermissionSet.exists?(legacy.id), 'visible only while no tenant is set'
      end

      test 'a permission record cannot be created while no tenant is set' do
        no_tenant!

        set = PermissionForge::PermissionSet.new(uuid: SecureRandom.uuid, name: 'No tenant')

        assert_not set.valid?
        assert_predicate set.errors[:account], :any?, 'acts_as_tenant requires the tenant association'
        assert_raises(ActiveRecord::RecordInvalid) { create_permission_set(name: 'No tenant') }
      end

      # --- cross-tenant references are rejected --------------------------------

      test 'assigning a user to another tenant permission set is rejected' do
        set_a = within(@tenant_a) { create_permission_set(name: 'A set') }

        within(@tenant_b) do
          assignment = PermissionForge::PermissionSetUser.new(uuid: SecureRandom.uuid, user: @user, permission_set: set_a)

          assert_not assignment.valid?
          assert_includes assignment.errors[:permission_set_id].join, 'ActsAsTenant'
          assert_raises(ActiveRecord::RecordInvalid) { assignment.save! }
        end
      end

      test 'a resource cannot be attached to another tenant permission set' do
        set_a = within(@tenant_a) { create_permission_set(name: 'A set') }

        within(@tenant_b) do
          assert_raises(ActiveRecord::RecordInvalid) { create_resource(permission_set: set_a, name: 'Customer') }
        end
      end

      test 'a permission set cannot join another tenant group' do
        group_a = within(@tenant_a) { create_permission_set_group(name: 'A group') }
        set_b = within(@tenant_b) { create_permission_set(name: 'B set') }

        within(@tenant_b) do
          assert_not set_b.update(permission_set_group: group_a)
          assert_includes set_b.errors[:permission_set_group_id].join, 'ActsAsTenant'
        end
      end

      test 'the tenant of a persisted row is immutable' do
        set_a = within(@tenant_a) { create_permission_set(name: 'A set') }

        assert_raises(ActsAsTenant::Errors::TenantIsImmutable) { set_a.account_id = @tenant_b.id }
      end

      # --- names, copies ------------------------------------------------------

      test 'the same permission set name can exist in two tenants' do
        within(@tenant_a) { create_permission_set(name: 'Sales') }

        within(@tenant_b) do
          assert_not PermissionForge::Admin::PermissionSetFactory.name_taken?('Sales')
          assert_nothing_raised { create_permission_set(name: 'Sales') }
        end
        within(@tenant_a) { assert PermissionForge::Admin::PermissionSetFactory.name_taken?('Sales') }
      end

      test 'a deep clone keeps every copied record inside the tenant' do
        within(@tenant_a) do
          graph = build_graph('A')

          copy = graph[:set].deep_clone(name: 'A copy')

          assert_equal @tenant_a.id, copy.account_id
          resource = copy.resources.sole
          assert_equal @tenant_a.id, resource.account_id
          assert_equal [@tenant_a.id], resource.resource_fields.pluck(:account_id).uniq
          assert_equal [@tenant_a.id], resource.resource_actions.pluck(:account_id).uniq
          assert_equal [@tenant_a.id], copy.permission_set_rules.pluck(:account_id).uniq
          assert_empty copy.permission_set_users
        end
      end

      test 'a group deep clone keeps the copied sets inside the tenant' do
        within(@tenant_a) do
          graph = build_graph('A')

          copy = graph[:group].deep_clone(name: 'A group copy')

          assert_equal @tenant_a.id, copy.account_id
          assert_equal [@tenant_a.id], copy.permission_sets.pluck(:account_id)
        end
      end

      # --- services inherit the scope -----------------------------------------

      test 'DashboardStats counts only the current tenant' do
        within(@tenant_a) { build_graph('A') }
        within(@tenant_b) do
          build_graph('B')
          create_permission_set(name: 'B extra')
        end

        within(@tenant_a) do
          stats = PermissionForge::Services::DashboardStats.call
          assert_equal 1, stats[:permission_sets_count]
          assert_equal 1, stats[:resources_count]
          assert_equal 1, stats[:rules_count]
          assert_equal 1, stats[:groups_count]
          assert_equal 1, stats[:users_count]
        end
        within(@tenant_b) { assert_equal 2, PermissionForge::Services::DashboardStats.call[:permission_sets_count] }
      end

      test 'StaleAssignmentAuditor only sees the current tenant' do
        within(@tenant_a) { build_graph('A')[:assignment].update_columns(created_at: 200.days.ago) }
        within(@tenant_b) { build_graph('B') }

        within(@tenant_a) { assert_equal 1, PermissionForge::Services::StaleAssignmentAuditor.call[:stale_count] }
        within(@tenant_b) { assert_equal 0, PermissionForge::Services::StaleAssignmentAuditor.call[:stale_count] }
      end

      test 'EffectiveAccess reports only the current tenant grants' do
        within(@tenant_a) { build_graph('A') }
        within(@tenant_b) do
          set = create_permission_set(name: 'B set')
          create_resource(permission_set: set, name: 'Supplier')
          create_permission_set_user(user: @user, permission_set: set)
        end

        within(@tenant_a) { assert_equal %w[Customer], PermissionForge::Admin::EffectiveAccess.call(user: @user).map(&:name) }
        within(@tenant_b) { assert_equal %w[Supplier], PermissionForge::Admin::EffectiveAccess.call(user: @user).map(&:name) }
      end

      test 'PeopleDirectory filters count assignments per tenant' do
        within(@tenant_a) { build_graph('A')[:assignment].update_columns(expires_at: 1.day.ago) }
        within(@tenant_b) { build_graph('B') }

        within(@tenant_a) { assert_equal 1, PermissionForge::Admin::PeopleDirectory.new.counts['expired'] }
        within(@tenant_b) { assert_equal 0, PermissionForge::Admin::PeopleDirectory.new.counts['expired'] }
      end

      private

      # One row of every permission model, all hanging off a single set.
      def build_graph(prefix)
        group = create_permission_set_group(name: "#{prefix} group")
        set = create_permission_set(name: "#{prefix} set", permission_set_group: group)
        resource = create_resource(permission_set: set, name: 'Customer')
        {
          group: group, set: set, resource: resource,
          field: create_resource_field(resource: resource, name: 'email'),
          action: create_resource_action(resource: resource),
          rule: create_permission_set_rule(permission_set: set, resource: resource),
          assignment: create_permission_set_user(user: @user, permission_set: set),
          membership: PermissionForge::PermissionSetGroupUser.create!(uuid: SecureRandom.uuid, user: @user,
                                                                      permission_set_group: group)
        }
      end
    end
  end
end
