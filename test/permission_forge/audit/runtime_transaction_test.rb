# frozen_string_literal: true

require 'test_helper'
require_relative 'runtime_support'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Audit
    # A runtime event is a decision that was made, whatever becomes of the
    # transaction it was made in: published at once, stored when the outermost
    # transaction has ended — committed or rolled back. Real transactions: what
    # the setup writes is committed, and removed again in teardown.
    class RuntimeTransactionTest < ActiveSupport::TestCase
      include RuntimeSupport
      include PermissionForge::Tenancy::TenancyTestHelper

      self.use_transactional_tests = false

      NotAuthorized = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @user = create_user(name: 'Ada')
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer')
        create_permission_set_rule(permission_set: @set, resource: @resource, include_nulls: false)
        @denied = create_customer(supplier_id: @user.id + 1000)
        @user.regenerate_permissions
        Current.user = @user
      end

      teardown do
        Customer.unscoped.where(id: @denied&.id).delete_all
        PermissionForge::PermissionSetRule.unscoped.where(permission_set_id: @set&.id).delete_all
        PermissionForge::Resource.unscoped.where(permission_set_id: @set&.id).delete_all
        PermissionForge::PermissionSetUser.unscoped.where(permission_set_id: @set&.id).delete_all
        PermissionForge::PermissionSet.unscoped.where(id: @set&.id).delete_all
        User.unscoped.where(id: @user&.id).delete_all
        PermissionForge::AuditEvent.unscoped.delete_all
        Account.where(id: [@tenant_a&.id, @tenant_b&.id]).delete_all
        ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT
      end

      def denials
        PermissionForge::AuditEvent.where(event: 'access.denied', record_id: @denied.id.to_s).count
      end

      test 'a denial that rolls its transaction back is published at once and stored after the rollback' do
        payloads = published('access.denied') do
          assert_raises(NotAuthorized) do
            ActiveRecord::Base.transaction do
              Customer.find_by!(uuid: @denied.uuid)
            end
          end
          assert_equal 1, denials
        end
        assert_equal([[false, true]], payloads.map { |p| p.values_at(:stored, :deferred) })
      end

      test 'a denial inside a transaction that commits is stored once it has committed, not before' do
        ActiveRecord::Base.transaction do
          assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied.uuid) }
          assert_equal 0, denials
        end
        assert_equal 1, denials
      end

      test 'a denial in a savepoint that rolls back is stored when the outer transaction ends' do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            Customer.find_by!(uuid: @denied.uuid)
          rescue NotAuthorized
            raise ActiveRecord::Rollback
          end
          assert_equal 0, denials
        end
        assert_equal 1, denials

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            Customer.find_by!(uuid: @denied.uuid)
          rescue NotAuthorized
            raise ActiveRecord::Rollback
          end
          raise ActiveRecord::Rollback
        end
        assert_equal 2, denials
      end

      def two_tenants!
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        within(@tenant_a) do
          @set_a = create_permission_set
          create_permission_set_user(user: @user, permission_set: @set_a)
          resource = create_resource(permission_set: @set_a, name: 'Customer')
          create_permission_set_rule(permission_set: @set_a, resource: resource, include_nulls: false)
          @denied_a = Customer.create!(uuid: SecureRandom.uuid, name: 'A', supplier_id: @user.id + 2000)
          @user.regenerate_permissions
        end
      end

      def remove_tenant_a!
        Customer.unscoped.where(id: @denied_a&.id).delete_all
        [PermissionForge::PermissionSetRule, PermissionForge::Resource, PermissionForge::PermissionSetUser].each do |model|
          model.unscoped.where(permission_set_id: @set_a&.id).delete_all
        end
        PermissionForge::PermissionSet.unscoped.where(id: @set_a&.id).delete_all
      end

      def tenants_of(event, **where)
        PermissionForge::AuditEvent.unscoped.where(event: event, **where).pluck(:account_id)
      end

      test 'a deferred denial keeps the tenant of the decision when the tenant switches before the rollback' do
        two_tenants!
        payloads = published('access.denied') do
          within(@tenant_a) do
            ActiveRecord::Base.transaction do
              assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied_a.uuid) }
              ActsAsTenant.test_tenant = @tenant_b
              raise ActiveRecord::Rollback
            end
          end
        end
        assert_equal([@tenant_a.id], payloads.map { |p| p[:tenant_id] })
        assert_equal [@tenant_a.id], tenants_of('access.denied', record_id: @denied_a.id.to_s)
      ensure
        remove_tenant_a!
      end

      test 'a deferred denial keeps the tenant of the decision when no tenant is ambient at the write' do
        two_tenants!
        within(@tenant_a) do
          ActiveRecord::Base.transaction do
            assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied_a.uuid) }
            no_tenant!
          end
        end
        assert_equal [@tenant_a.id], tenants_of('access.denied', record_id: @denied_a.id.to_s)
      ensure
        remove_tenant_a!
      end

      test 'a deferred refusal (Audit::Detached) keeps the tenant of the moment it happened' do
        two_tenants!
        within(@tenant_a) do
          ActiveRecord::Base.transaction do
            Detached.record('admin.auth_failed', actor: { type: 'basic_auth', label: 'mallory' }, source: 'admin_ui')
            ActsAsTenant.test_tenant = @tenant_b
            raise ActiveRecord::Rollback
          end
          ActsAsTenant.test_tenant = @tenant_a
          ActiveRecord::Base.transaction do
            Detached.record('admin.auth_failed', actor: { type: 'basic_auth', label: 'eve' }, source: 'admin_ui')
            no_tenant!
          end
        end
        assert_equal [@tenant_a.id], tenants_of('admin.auth_failed', actor_label: 'mallory')
        assert_equal [@tenant_a.id], tenants_of('admin.auth_failed', actor_label: 'eve')
      ensure
        remove_tenant_a!
      end

      test 'a connection that cannot answer at a savepoint rollback does not raise; the block still runs' do
        runs = []
        reports = []
        reporter = Rails.error
        reporter.define_singleton_method(:report) { |error, **| reports << error.message }
        connection = ActiveRecord::Base.connection
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) do
            OpenTransaction.current.after_end { runs << :ended }
            # only OpenTransaction's question fails; Rails' own rollback goes on
            connection.define_singleton_method(:active?) do
              raise 'connection gone' if caller.any? { |frame| frame.include?('open_transaction.rb') }

              true
            end
            raise ActiveRecord::Rollback
          end
        end
        assert_equal [:ended], runs
        assert_equal ['connection gone'], reports
      ensure
        connection.singleton_class.send(:remove_method, :active?) if connection&.singleton_class&.method_defined?(:active?, false)
        reporter.singleton_class.send(:remove_method, :report)
      end

      test 'outside a transaction the denial is stored at once and the notification carries it' do
        payloads = published('access.denied') { assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied.uuid) } }
        assert_equal([[true, false]], payloads.map { |p| p.values_at(:stored, :deferred) })
        assert_kind_of PermissionForge::AuditEvent, payloads.first[:audit_event]
      end
    end
  end
end
