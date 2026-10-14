# frozen_string_literal: true

require_relative 'integration_support'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module AuditIntegration
    # The data-subject flows through the admin UI: erasure and consent
    # withdrawal revoke row by row (one event each), write one summary, and
    # erasure forgets the person's name on every event of the admin's tenant
    # that carried it — another tenant's log is out of its reach — while
    # every id stays. Previews and dry runs write nothing.
    class GdprFlowsTest < ActionDispatch::IntegrationTest
      include IntegrationSupport
      include Tenancy::TenancyTestHelper

      ANA = 'Ana Krasniqi'

      setup do
        @admin = create_user(name: ADMIN_NAME)
        @ana = create_user(name: ANA)
        @bo = create_user(name: 'Bo Berisha')
        @tenant_b = Account.create!(name: 'Tenant B')
        @set = create_permission_set(name: 'Sales rep')
        @gated = create_permission_set(name: 'Newsletter', requires_session_flag: 'marketing_consent')
        @group = create_permission_set_group(name: 'Sales team')
        @rows = [@set, @gated].map { |set| create_permission_set_user(user: @ana, permission_set: set) }
        @membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @ana)
        @bo_row = create_permission_set_user(user: @bo, permission_set: @set)
      end

      test 'erasure revokes row by row, records one summary and forgets the name in the tenant, keeping the ids' do
        ana_acted_in_both_tenants
        sign_in(@admin)

        post "#{ROOT}/people/#{@ana.id}/erasure", params: { confirmation: ANA, reason: 'GDPR ticket 77' }
        assert_response :redirect

        revoked = @rows.map { |row| assert_audit_event('assignment.revoked', record_id: row.id.to_s, actor_id: @admin.id.to_s) }
        removed = assert_audit_event('group_membership.removed', record_id: @membership.id.to_s)
        summary = assert_audit_event('erasure.performed', subject_user_id: @ana.id.to_s, actor_label: ADMIN_NAME, reason: 'GDPR ticket 77')
        assert_equal 1, (revoked + [removed, summary]).map(&:correlation_id).uniq.size
        assert_equal({ 'assignments_removed' => 2, 'group_assignments_removed' => 1, 'assignments_remaining_elsewhere' => 1 },
                     summary.data.slice('assignments_removed', 'group_assignments_removed', 'assignments_remaining_elsewhere'))
        assert_name_forgotten_in_own_tenant_only
        assert_equal 'Bo Berisha', assert_audit_event('assignment.granted', record_id: @bo_row.id.to_s).record_label, 'others keep theirs'
      end

      test 'consent withdrawal revokes the gated rows one by one and records one summary' do
        sign_in(@admin)

        post "#{ROOT}/people/#{@ana.id}/consent", params: { flag: 'marketing_consent', reason: 'User request 12' }

        gated_row = @rows.last
        revoked = assert_audit_event('assignment.revoked', record_id: gated_row.id.to_s, subject_user_id: @ana.id.to_s,
                                                           reason: 'User request 12')
        summary = assert_audit_event('consent.withdrawn', subject_user_id: @ana.id.to_s, actor_id: @admin.id.to_s, source: 'admin_ui',
                                                          data: { 'consent_flag' => 'marketing_consent', 'revoked' => 1,
                                                                  'set_names' => ['Newsletter'] })
        assert_equal revoked.correlation_id, summary.correlation_id
        assert PermissionSetUser.exists?(@rows.first.id), 'a set not gated on the flag is kept'
        assert_equal ANA, revoked.record_label, 'consent withdrawal forgets nothing'
      end

      test 'previews and dry runs write nothing' do
        sign_in(@admin)

        assert_no_difference -> { AuditEvent.unscoped.count } do
          get "#{ROOT}/people/#{@ana.id}/erasure"
          get "#{ROOT}/people/#{@ana.id}/consent", params: { flag: 'marketing_consent' }
          post "#{ROOT}/people/#{@ana.id}/erasure", params: { confirmation: 'not the name' }
          Services::DataSubjectErasure.call(user: @ana, dry_run: true, actor: @admin)
          Services::ConsentWithdrawalHandler.call(user: @ana, consent_flag: 'marketing_consent', dry_run: true, actor: @admin)
          with_env('USER_ID' => @ana.id.to_s, 'DRY_RUN' => nil, 'ACTOR' => 'ops') { run_rake_task('permission_forge:erasure') }
        end
        assert_equal 2, PermissionSetUser.where(user_id: @ana.id).count
      end

      private

      # Events by Ana (an admin herself) and about her, in the default tenant and in tenant B.
      def ana_acted_in_both_tenants
        sign_in(@ana)
        patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { description: 'Edited by Ana' } } }
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'B set')
          @row_b = create_permission_set_user(user: @ana, permission_set: @set_b)
          patch "#{ROOT}/permission_sets/#{@set_b.id}/apply", params: { pf: { set: { description: 'Edited by Ana in B' } } }
        end
      end

      def assert_name_forgotten_in_own_tenant_only
        assert_forgotten(AuditEvent.unscoped.where(actor_type: 'user', actor_id: @ana.id.to_s), :actor_label)
        assert_forgotten(AuditEvent.unscoped.where(subject_user_id: @ana.id.to_s), :record_label)
        assert PermissionSetUser.unscoped.exists?(@row_b.id), 'assignments in another tenant are not removed'
      end

      # The events of the admin's tenant keep the id and lose the name; the
      # other tenant's keep both.
      def assert_forgotten(events, label)
        assert_equal [DEFAULT_TEST_ACCOUNT.id, @tenant_b.id].sort, events.distinct.pluck(:account_id).sort, "#{label}: both tenants"
        assert_equal [nil], events.where(account_id: DEFAULT_TEST_ACCOUNT.id).distinct.pluck(label), "#{label} is forgotten"
        assert_equal [ANA], events.where(account_id: @tenant_b.id).distinct.pluck(label), "#{label}: tenant B keeps it"
      end
    end
  end
end
