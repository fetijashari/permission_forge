# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module ReleaseReadiness
    # Pre-release re-review, integrity lane: the maintenance services
    # run with no tenant (the rake tasks, a console, a platform job).
    #
    # INT-N3: docs/multi-tenancy.md recommends acts_as_tenant's
    # `require_tenant = true` and says the maintenance tasks span every
    # tenant when run without one; under that setting the cleaner, the
    # erasure, the stale-assignment report and the consent withdrawal raised
    # ActsAsTenant::Errors::NoTenantSet instead.
    #
    # INT-N4: their tenant-less summary events had no tenant, so no tenant's
    # auditors saw them; they are now written per tenant (and once as the
    # total), like audit.purged.
    class TenantlessMaintenanceRegressionTest < ActiveSupport::TestCase
      include PermissionForge::Tenancy::TenancyTestHelper

      Services = PermissionForge::Services

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @user = create_user(name: 'Shared Person')
      end

      teardown do
        ActsAsTenant.configuration.require_tenant = false
        ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT
      end

      def assignment_in(tenant, name:, **attrs)
        within(tenant) do
          set = create_permission_set(name: name, **attrs.slice(:requires_session_flag))
          create_permission_set_user(user: @user, permission_set: set, **attrs.except(:requires_session_flag))
        end
      end

      def expire!(*assignments)
        PermissionForge::PermissionSetUser.unscoped.where(id: assignments.map(&:id)).update_all(expires_at: 1.day.ago) # test setup
      end

      def summaries(event)
        PermissionForge::AuditEvent.unscoped.where(event: event).order(:id).to_a
      end

      def tenantless_with_require_tenant!
        no_tenant!
        ActsAsTenant.configuration.require_tenant = true
      end

      # ---- INT-N3 -------------------------------------------------------------------

      test 'INT-N3 the cleaner runs tenant-less under require_tenant and removes every tenant’s expired rows' do
        expire!(assignment_in(@tenant_a, name: 'A'), assignment_in(@tenant_b, name: 'B'))
        tenantless_with_require_tenant!

        dry = Services::ExpiredAssignmentCleaner.call(dry_run: true)
        result = Services::ExpiredAssignmentCleaner.call

        assert_equal 2, dry[:expired_count]
        assert_equal 2, result[:removed]
        assert_empty PermissionForge::PermissionSetUser.unscoped.where(user_id: @user.id)
      end

      test 'INT-N3 erasure, its dry run and the stale report run tenant-less under require_tenant' do
        assignment_in(@tenant_a, name: 'A')
        assignment_in(@tenant_b, name: 'B')
        PermissionForge::PermissionSetUser.unscoped.where(user_id: @user.id).update_all(created_at: 1.year.ago) # test setup
        tenantless_with_require_tenant!

        assert_equal(2, Services::StaleAssignmentAuditor.call[:assignments].count { |row| row[:user_id] == @user.id })
        assert_equal 2, Services::DataSubjectErasure.call(user: @user, dry_run: true)[:assignments_count]
        assert_equal 2, Services::DataSubjectErasure.call(user: @user)[:assignments_removed]
        assert_empty PermissionForge::PermissionSetUser.unscoped.where(user_id: @user.id)
      end

      test 'INT-N3 consent withdrawal runs tenant-less under require_tenant' do
        assignment_in(@tenant_a, name: 'A', requires_session_flag: 'marketing')
        assignment_in(@tenant_b, name: 'B', requires_session_flag: 'marketing')
        tenantless_with_require_tenant!

        dry = Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing', dry_run: true)
        result = Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing')

        assert_equal 2, dry[:affected_assignment_count]
        assert_equal 2, result[:revoked_sets]
      end

      test 'INT-N3 with a tenant current the services stay in that tenant' do
        expire!(assignment_in(@tenant_a, name: 'A'), kept = assignment_in(@tenant_b, name: 'B'))
        ActsAsTenant.configuration.require_tenant = true

        result = within(@tenant_a) { Services::ExpiredAssignmentCleaner.call }

        assert_equal 1, result[:removed]
        assert PermissionForge::PermissionSetUser.unscoped.exists?(kept.id)
      end

      # ---- INT-N4 -------------------------------------------------------------------

      test 'INT-N4 a tenant-less cleanup is recorded in each tenant with its own counts, and as the total' do
        expire!(assignment_in(@tenant_a, name: 'A1'), assignment_in(@tenant_a, name: 'A2'), assignment_in(@tenant_b, name: 'B'))
        no_tenant!

        assert_difference -> { summaries('cleanup.expired_assignments').size }, 3 do
          Services::ExpiredAssignmentCleaner.call
        end

        by_tenant = summaries('cleanup.expired_assignments').last(3).index_by(&:account_id)
        assert_equal [2, %w[A1 A2], true], by_tenant[@tenant_a.id].data.values_at('removed', 'set_names', 'across_tenants')
        assert_equal [1, %w[B], true], by_tenant[@tenant_b.id].data.values_at('removed', 'set_names', 'across_tenants')
        assert_equal [3, 2, true], by_tenant[nil].data.values_at('removed', 'tenants', 'across_tenants')
        assert_equal 1, within(@tenant_a) { PermissionForge::AuditEvent.where(event: 'cleanup.expired_assignments').count }
      end

      test 'INT-N4 a tenant-less consent withdrawal is recorded in each tenant, and as the total' do
        assignment_in(@tenant_a, name: 'A', requires_session_flag: 'marketing')
        assignment_in(@tenant_b, name: 'B', requires_session_flag: 'marketing')
        no_tenant!

        Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing')

        by_tenant = summaries('consent.withdrawn').last(3).index_by(&:account_id)
        assert_equal([[1, %w[A]], [1, %w[B]], [2, %w[A B]]],
                     [@tenant_a.id, @tenant_b.id, nil].map { |id| by_tenant.fetch(id).data.values_at('revoked', 'set_names') })
        assert(by_tenant.values.all? { |event| event.subject_user_id == @user.id.to_s && event.data['across_tenants'] })
      end

      test 'INT-N4 with a tenant current the summary is one event in that tenant, as before' do
        expire!(assignment_in(@tenant_a, name: 'A'))

        assert_difference -> { summaries('cleanup.expired_assignments').size }, 1 do
          within(@tenant_a) { Services::ExpiredAssignmentCleaner.call }
        end

        event = summaries('cleanup.expired_assignments').last
        assert_equal @tenant_a.id, event.account_id
        assert_nil event.data['across_tenants']
      end
    end
  end
end
