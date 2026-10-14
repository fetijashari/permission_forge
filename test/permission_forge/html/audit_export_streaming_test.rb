require_relative 'admin_test_case'
require_relative '../admin/csv_reading'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Html
    # The exports are written after the action's around_actions have ended, so
    # what the rows need from the request (suspended record rules, the tenant)
    # is carried into the body: AuditEventsController#pf_stream.
    class AuditExportStreamingTest < AdminTestCase
      include PermissionForge::Tenancy::TenancyTestHelper

      # A host that sets the tenant in an around_action of its own. Prepended:
      # a host's callbacks (in base_controller_class) run before the engine's,
      # so the tenant is in place when the admin checks for one.
      class << self
        attr_accessor :host_tenant
      end

      PermissionForge::AuditEventsController.around_action(prepend: true) do |_controller, action|
        tenant = AuditExportStreamingTest.host_tenant
        tenant ? ActsAsTenant.with_tenant(tenant) { action.call } : action.call
      end

      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        @old_scoping = PermissionForge.configuration.auto_query_scoping
        @admin = create_user(name: 'Ada Admin')
        admin = @admin
        PermissionForge.configuration.current_user_resolver = -> { admin }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
        PermissionForge.configuration.auto_query_scoping = @old_scoping
        self.class.host_tenant = nil
        no_tenant!
        ActsAsTenant.configuration.require_tenant = false
      end

      def holdings
        get pf('/audit/holdings.csv')
        _meta, header, rows = PermissionForge::Admin::CsvReading.export(response.body)
        rows.map { |row| header.zip(row).to_h }
      end

      def two_tenants
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        within(@tenant_a) do
          @set_a = create_permission_set(name: 'Alphaset')
          create_permission_set_user(user: @ana, permission_set: @set_a, created_by_id: @bo.id)
        end
        within(@tenant_b) { create_permission_set(name: 'Bravoset') }
      end

      # The user model scoped to the admin's own row unless record rules are
      # suspended: what PermissionScopedFindable's auto-scoping does for an
      # admin whose rule is `name = 'Ada Admin'`, without mixing the concern
      # (or MaskedAttributes, through a Resource row named User) into the
      # dummy's User for the rest of the test process.
      test 'who holds what names people although the admin has a record rule on the user model' do
        saved = User.default_scopes
        User.send(:default_scope) { where(name: 'Ada Admin') unless PermissionForge.scope_suspended? }
        assert_equal ['Ada Admin'], User.pluck(:name), 'the rule applies outside the export'

        row = holdings.find { |r| r['assignment_id'] == @assignment.id.to_s }

        assert_equal 'Ana Krasniqi', row['person']
      ensure
        User.default_scopes = saved
      end

      test 'who holds what keeps the action tenant when the host sets it in an around_action and requires one' do
        two_tenants
        no_tenant!
        ActsAsTenant.configuration.require_tenant = true
        self.class.host_tenant = @tenant_a

        rows = holdings

        assert_equal ['Alphaset'], rows.pluck('permission_set')
        assert_equal ['Ada Admin'], rows.pluck('granted_by'), 'the grant event of the tenant, not the created_by fallback'
      end

      test 'who holds what reads the action tenant, not the one ambient while the body is written' do
        two_tenants
        ActsAsTenant.test_tenant = @tenant_b
        self.class.host_tenant = @tenant_a

        rows = holdings

        assert_equal ['Alphaset'], rows.pluck('permission_set')
        assert_equal ['Ada Admin'], rows.pluck('granted_by'), 'the grant event of the tenant, not the created_by fallback'
      end

      test 'the audit log export stays in the action tenant when the host sets it in an around_action' do
        two_tenants
        no_tenant!
        ActsAsTenant.configuration.require_tenant = true
        self.class.host_tenant = @tenant_a

        get pf('/audit.json')
        body = JSON.parse(response.body)

        assert_operator body['meta']['row_count'], :>, 0
        assert_equal body['meta']['row_count'], body['data'].size
        sets = body['data'].filter_map { |event| event['permission_set_id'] }.uniq

        assert_equal [@set_a.id], sets, 'only the events of the action tenant'
      end
    end
  end
end
