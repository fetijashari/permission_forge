require 'test_helper'

module PermissionForge
  module Security
    # Level 2 — DETECT (config.unscoped_query_detection = :log | :raise).
    class UnscopedQueryDetectionTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @permission_set)
        @resource = create_resource(permission_set: @permission_set, name: 'Customer')
        @customer = create_customer(supplier_id: @user.id)
        @user.regenerate_permissions
        Current.user = @user
        Services::UnscopedQueryDetector.install!
      end

      teardown do
        Services::UnscopedQueryDetector.uninstall!
        PermissionForge.configuration.unscoped_query_detection = :off
        PermissionForge.configuration.auto_query_scoping = :off
      end

      # --- :raise mode ---

      test 'bare where raises UnscopedQueryError in :raise mode' do
        enable_detection(:raise)

        assert_raises(PermissionForge::UnscopedQueryError) { Customer.where(name: 'x').to_a }
      end

      test 'association traversal raises in :raise mode' do
        supplier = create_supplier
        enable_detection(:raise)

        assert_raises(PermissionForge::UnscopedQueryError) { supplier.customers.to_a }
      end

      test 'permission_scoped chains are not flagged' do
        enable_detection(:raise)

        assert_equal [@customer.uuid], Customer.permission_scoped.where(uuid: @customer.uuid).pluck(:uuid)
      end

      test 'find_by is not flagged' do
        enable_detection(:raise)

        assert_equal @customer.uuid, Customer.find_by(uuid: @customer.uuid).uuid
      end

      test 'without_permission_scope silences detection' do
        enable_detection(:raise)

        PermissionForge.without_permission_scope do
          assert_equal Customer.count, Customer.all.size
        end
      end

      test 'INSERTs are never flagged' do
        enable_detection(:raise)

        record = Customer.create!(uuid: SecureRandom.uuid, name: 'ok', email: 'ok@example.com',
                                  domain: 'example.com')
        assert record.persisted?
      end

      test 'queries on unprotected tables are never flagged' do
        enable_detection(:raise)

        assert Supplier.where(name: 'anything').to_a.is_a?(Array)
      end

      # --- interplay with Level 1 ---

      test 'with auto scoping on, ordinary queries are quiet and unscoped is flagged' do
        create_permission_set_rule(permission_set: @permission_set, resource: @resource)
        @user.regenerate_permissions
        PermissionForge.configuration.auto_query_scoping = :filter_only
        enable_detection(:raise)

        # Auto-scoped query carries the annotation — compliant.
        assert_includes Customer.where.not(uuid: nil).pluck(:uuid), @customer.uuid
        # unscoped drops the default scope (and the annotation) — a true escape.
        assert_raises(PermissionForge::UnscopedQueryError) { Customer.unscoped.to_a }
      end

      test 'find_by_sql is flagged in :raise mode' do
        enable_detection(:raise)

        assert_raises(PermissionForge::UnscopedQueryError) do
          Customer.find_by_sql('SELECT * FROM customers')
        end
      end

      # --- :log mode ---

      test 'log mode warns with table name and call site instead of raising' do
        enable_detection(:log)
        io = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)

        begin
          Customer.where(name: 'x').to_a
        ensure
          Rails.logger = original_logger
        end

        assert_includes io.string, "protected table 'customers'"
        assert_includes io.string, '[PermissionForge]'
      end

      # --- gating ---

      test 'detection is inert in environments outside the allowlist' do
        enable_detection(:raise)
        PermissionForge.configuration.unscoped_query_detection_environments = %w[development]

        assert Customer.where(name: 'x').to_a.is_a?(Array)
      end

      test 'detection is off by default' do
        assert Customer.where(name: 'x').to_a.is_a?(Array)
      end

      test 'invalid unscoped_query_detection value raises at assignment' do
        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge.configuration.unscoped_query_detection = :explode
        end
      end

      private

      def enable_detection(mode)
        PermissionForge.configuration.unscoped_query_detection = mode
      end
    end
  end
end
