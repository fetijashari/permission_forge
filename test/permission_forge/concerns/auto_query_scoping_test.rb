require 'test_helper'

# Host-model shims proving the auto-scope preserves an existing default_scope
# (soft-delete style) in BOTH declaration orders. Table reuse is deliberate —
# they are plain AR classes over the customers table.
class SoftDeleteFirstCustomer < ActiveRecord::Base
  self.table_name = 'customers'
  default_scope { where(domain: 'example.com') }
  include PermissionForge::Concerns::PermissionScopedFindable
end

class SoftDeleteLastCustomer < ActiveRecord::Base
  self.table_name = 'customers'
  include PermissionForge::Concerns::PermissionScopedFindable

  default_scope { where(domain: 'example.com') }
end

module PermissionForge
  module Concerns
    # Level 1 — ENFORCE (config.auto_query_scoping = :filter_only).
    class AutoQueryScopingTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
        @mine = create_customer(name: 'Mine', supplier_id: nil)
        @owned = create_customer(name: 'Owned', supplier_id: nil)
      end

      teardown do
        PermissionForge.configuration.auto_query_scoping = :off
        Customer.permission_forge_auto_scope = true
      end

      # --- enforcement over relation paths ---

      test 'where/all/count/pluck are unscoped by default (:off)' do
        add_current_user_rule
        denied = create_denied_customer

        assert_includes Customer.where(name: denied.name).pluck(:uuid), denied.uuid
        assert_includes Customer.all.pluck(:uuid), denied.uuid
      end

      test 'where is scoped under :filter_only' do
        add_current_user_rule
        enable_auto_scoping
        mine = create_customer(supplier_id: @user.id)
        denied = create_denied_customer

        uuids = Customer.where.not(uuid: nil).pluck(:uuid)
        assert_includes uuids, mine.uuid
        refute_includes uuids, denied.uuid
      end

      test 'all, count and first are scoped under :filter_only' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        mine = create_customer(supplier_id: @user.id)
        create_denied_customer

        assert_equal [mine.uuid], Customer.all.pluck(:uuid)
        assert_equal 1, Customer.count
        assert_equal mine.uuid, Customer.first.uuid
      end

      test 'find raises RecordNotFound for a denied row under :filter_only' do
        add_current_user_rule
        enable_auto_scoping
        denied = create_denied_customer

        assert_raises(ActiveRecord::RecordNotFound) { Customer.find(denied.id) }
      end

      test 'association traversal is scoped under :filter_only' do
        supplier = create_supplier
        allowed = create_customer(name: 'Allowed', supplier_id: supplier.id)
        blocked = create_customer(name: 'Blocked', supplier_id: supplier.id)
        add_rule(operator: 'equal', field_name: 'name', field_value: 'Allowed', include_nulls: false)
        enable_auto_scoping

        uuids = supplier.customers.pluck(:uuid)
        assert_includes uuids, allowed.uuid
        refute_includes uuids, blocked.uuid
      end

      test 'includes works and stays scoped under :filter_only' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        mine = create_customer(supplier_id: @user.id)
        create_denied_customer

        loaded = Customer.includes(:supplier).to_a
        assert_equal [mine.uuid], loaded.map(&:uuid)
      end

      test 'annotation marks auto-scoped SQL as compliant' do
        add_current_user_rule
        enable_auto_scoping

        assert_includes Customer.all.to_sql, '/* pf_scoped */'
      end

      # --- creation paths (regression: scope_for_create SqlLiteral crash) ---

      test 'create! works for a scoped user with an equal rule (no include_nulls)' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping

        record = Customer.create!(uuid: SecureRandom.uuid, name: 'Created', email: 'c@example.com',
                                  domain: 'example.com', supplier_id: @user.id)
        assert record.persisted?
        # The rule predicate must NOT leak into new-record attributes.
        assert_nil Customer.new.supplier_id
      end

      test 'create! works for a scoped user with an is_null rule' do
        add_rule(operator: 'is_null', field_value: '', include_nulls: false)
        enable_auto_scoping

        record = Customer.create!(uuid: SecureRandom.uuid, name: 'Created', email: 'c2@example.com',
                                  domain: 'example.com', supplier_id: nil)
        assert record.persisted?
      end

      test 'association create! works under :filter_only' do
        supplier = create_supplier
        add_current_user_rule
        enable_auto_scoping

        record = supplier.customers.create!(uuid: SecureRandom.uuid, name: 'Assoc', email: 'a@example.com',
                                            domain: 'example.com')
        assert record.persisted?
        assert_equal supplier.id, record.supplier_id
      end

      # --- find_by contract preserved (no double application) ---

      test 'find_by! still raises NotAuthorizedError (not RecordNotFound) for a denied row under :filter_only' do
        add_current_user_rule
        enable_auto_scoping
        denied = create_denied_customer

        assert_raises(PermissionScopedFindable::NotAuthorizedError) do
          Customer.find_by!(uuid: denied.uuid)
        end
      end

      test 'find_by returns nil for a genuinely missing record under :filter_only' do
        add_current_user_rule
        enable_auto_scoping

        assert_nil Customer.find_by(uuid: 'no-such-uuid')
      end

      test 'permission_scoped does not double-apply rules under :filter_only' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        mine = create_customer(supplier_id: @user.id)

        relation_sql = Customer.permission_scoped.to_sql
        assert_equal 1, relation_sql.scan('supplier_id').size, relation_sql
        assert_equal [mine.uuid], Customer.permission_scoped.pluck(:uuid)
      end

      # --- bypasses and strategies ---

      test 'view_all bypasses auto-scoping' do
        @resource.update!(view_all: true)
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        denied = create_denied_customer

        assert_includes Customer.all.pluck(:uuid), denied.uuid
      end

      test 'join-type rules are not auto-applied (filter_only)' do
        supplier = create_supplier(owner_id: @user.id + 999)
        add_rule(operator: 'equal', field_name: 'owner_id', field_value: 'current_user',
                 join_type: 'joins', field_accessor_path: 'supplier', include_nulls: false)
        enable_auto_scoping
        via_other_supplier = create_customer(supplier_id: supplier.id)

        # Bare relation ignores the join rule…
        assert_includes Customer.all.pluck(:uuid), via_other_supplier.uuid
        # …but permission_scoped still enforces it.
        refute_includes Customer.permission_scoped.pluck(:uuid), via_other_supplier.uuid
      end

      test 'nil user with :bypass returns unscoped relation' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        Current.user = nil

        assert_equal Customer.unscoped.count, Customer.all.count
      end

      test 'nil user with :deny returns empty relation (fail closed)' do
        add_current_user_rule
        enable_auto_scoping
        Current.user = nil
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_equal 0, Customer.all.count
      end

      test 'nil user with :raise fails closed to empty relation instead of raising' do
        add_current_user_rule
        enable_auto_scoping
        Current.user = nil
        PermissionForge.configuration.nil_user_strategy = :raise

        assert_equal 0, Customer.all.count
      end

      test 'users with no rules see everything under :filter_only' do
        setup_permissions # no rules created
        enable_auto_scoping(skip_user: true)
        denied = create_customer(supplier_id: @user.id + 999)

        assert_includes Customer.all.pluck(:uuid), denied.uuid
      end

      # --- escape hatches ---

      test 'without_permission_scope suspends auto-scoping and is nesting-safe' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        denied = create_denied_customer

        PermissionForge.without_permission_scope do
          PermissionForge.without_permission_scope do
            assert_includes Customer.all.pluck(:uuid), denied.uuid
          end
          # Inner block exit must not re-enable scoping for the outer block.
          assert_includes Customer.all.pluck(:uuid), denied.uuid
        end
        refute_includes Customer.all.pluck(:uuid), denied.uuid
      end

      test 'per-model opt-out disables auto-scoping for that model' do
        add_current_user_rule(include_nulls: false)
        enable_auto_scoping
        denied = create_denied_customer
        Customer.permission_forge_auto_scope = false

        assert_includes Customer.all.pluck(:uuid), denied.uuid
      end

      test 'invalid auto_query_scoping value raises at assignment' do
        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge.configuration.auto_query_scoping = :everything
        end
      end

      # --- host default_scope preservation (both declaration orders) ---

      test 'host default_scope declared before include is preserved' do
        assert_host_default_scope_preserved(SoftDeleteFirstCustomer)
      end

      test 'host default_scope declared after include is preserved' do
        assert_host_default_scope_preserved(SoftDeleteLastCustomer)
      end

      private

      def assert_host_default_scope_preserved(klass)
        shim_resource = create_resource(permission_set: @permission_set, name: klass.name)
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: false,
                 resource: shim_resource)
        enable_auto_scoping
        visible = create_customer(supplier_id: @user.id, domain: 'example.com')
        soft_deleted = create_customer(supplier_id: @user.id, domain: 'other.com')

        uuids = klass.all.pluck(:uuid)
        assert_includes uuids, visible.uuid
        refute_includes uuids, soft_deleted.uuid, "#{klass.name} lost its own default_scope"
      end

      def add_current_user_rule(include_nulls: true)
        add_rule(operator: 'equal', field_value: 'current_user', include_nulls: include_nulls)
      end

      def add_rule(resource: @resource, **attrs)
        create_permission_set_rule(permission_set: @permission_set, resource: resource, **attrs)
      end

      def create_denied_customer
        create_customer(supplier_id: @user.id + 999)
      end

      def setup_permissions
        @user.regenerate_permissions
        Current.user = @user
      end

      def enable_auto_scoping(skip_user: false)
        setup_permissions unless skip_user
        PermissionForge.configuration.auto_query_scoping = :filter_only
      end
    end
  end
end
