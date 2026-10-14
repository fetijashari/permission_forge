require 'test_helper'
require_relative 'tenancy_test_helper'

# Host-model shims: a protected model that is ALSO tenant-scoped, in both
# declaration orders (acts_as_tenant before and after the concern). Plain AR
# classes over the customers table, like the soft-delete shims in
# auto_query_scoping_test.rb.
class TenantFirstCustomer < ActiveRecord::Base
  self.table_name = 'customers'
  acts_as_tenant :account
  include PermissionForge::Concerns::PermissionScopedFindable
end

class TenantLastCustomer < ActiveRecord::Base
  self.table_name = 'customers'
  include PermissionForge::Concerns::PermissionScopedFindable

  acts_as_tenant :account
end

module PermissionForge
  module Tenancy
    # PermissionScopedFindable on a tenant-scoped host model: every path —
    # no rules, View All bypass, rules, permission_scoped, Level 1 auto
    # scoping and the without_permission_scope escape hatch — keeps the tenant
    # scope, and a row from another tenant looks missing, never "denied".
    class TenantScopedFindableTest < ActiveSupport::TestCase
      include TenancyTestHelper

      SHIMS = [TenantFirstCustomer, TenantLastCustomer].freeze
      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user
        ActsAsTenant.test_tenant = @tenant_a

        @set = create_permission_set(name: 'A set')
        @resources = SHIMS.index_with { |shim| create_resource(permission_set: @set, name: shim.name, read_access: true) }
        create_permission_set_user(user: @user, permission_set: @set)

        @mine = create_customer(name: 'Mine', supplier_id: @user.id, account_id: @tenant_a.id)
        @denied = create_customer(name: 'Denied', supplier_id: @user.id + 1, account_id: @tenant_a.id)
        @foreign = create_customer(name: 'Foreign', supplier_id: @user.id, account_id: @tenant_b.id)
        Current.user = @user
      end

      teardown do
        PermissionForge.configuration.auto_query_scoping = :off
      end

      SHIMS.each do |shim|
        test "#{shim.name}: find_by ignores another tenant row when no rules apply" do
          assert_equal @mine.id, shim.find_by(id: @mine.id)&.id
          assert_nil shim.find_by(id: @foreign.id)
        end

        test "#{shim.name}: find_by ignores another tenant row under View All" do
          @resources[shim].update!(view_all: true)

          assert_equal @mine.id, shim.find_by(id: @mine.id)&.id
          assert_nil shim.find_by(id: @foreign.id)
        end

        test "#{shim.name}: with rules, another tenant row is missing, never denied" do
          add_rule(shim)

          assert_equal @mine.id, shim.find_by(id: @mine.id)&.id
          assert_raises(NotAuthorizedError) { shim.find_by(id: @denied.id) }
          assert_nil shim.find_by(id: @foreign.id), 'a cross-tenant row must look missing, not denied'
          assert_raises(ActiveRecord::RecordNotFound) { shim.find_by!(id: @foreign.id) }
        end

        test "#{shim.name}: permission_scoped never crosses the tenant" do
          add_rule(shim)

          ids = shim.permission_scoped.pluck(:id)
          assert_includes ids, @mine.id
          refute_includes ids, @denied.id
          refute_includes ids, @foreign.id
        end

        test "#{shim.name}: Level 1 auto scoping keeps the tenant scope" do
          add_rule(shim)
          PermissionForge.configuration.auto_query_scoping = :filter_only

          assert_equal [@mine.id], shim.all.pluck(:id)
          assert_equal 1, shim.count
          assert_raises(ActiveRecord::RecordNotFound) { shim.find(@foreign.id) }
        end

        test "#{shim.name}: without_permission_scope lifts the rules but not the tenant" do
          add_rule(shim)
          PermissionForge.configuration.auto_query_scoping = :filter_only

          ids = PermissionForge.without_permission_scope { shim.pluck(:id) }
          assert_includes ids, @denied.id
          refute_includes ids, @foreign.id
        end
      end

      test 'switching tenant switches which rows a user can find' do
        within(@tenant_b) do
          assert_nil TenantFirstCustomer.find_by(id: @mine.id)
          assert_equal @foreign.id, TenantFirstCustomer.find_by(id: @foreign.id)&.id
        end
      end

      private

      def add_rule(shim)
        create_permission_set_rule(permission_set: @set, resource: @resources[shim],
                                   field_name: 'supplier_id', field_value: 'current_user', operator: 'equal',
                                   include_nulls: false)
      end
    end
  end
end
