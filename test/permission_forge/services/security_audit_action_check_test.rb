require_relative '../admin/action_catalog_support'

# A guarded controller of a resource no Permission Set manages in these tests.
class PfStubGuardedSuppliersController < ActionController::Base
  include PermissionForge::Concerns::ControllerActionGuard

  permission_forge_actions resource: 'Supplier'
end

module PermissionForge
  module Services
    # SecurityAuditChecks::ActionCheck — controller actions as permissions.
    class SecurityAuditActionCheckTest < ActiveSupport::TestCase
      include PermissionForge::Admin::ActionCatalogSupport

      setup do
        @config = PermissionForge::Configuration.new
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set)
      end

      def findings(catalog: nil, **overrides)
        overrides.each { |key, value| @config.public_send("#{key}=", value) }
        SecurityAuditChecks::ActionCheck.new(configuration: @config, environment: 'test', catalog: catalog).call
      end

      def finding(code, **)
        findings(**).find { |item| item.code == code }
      end

      test 'is part of the audit and quiet on a setup without actions' do
        assert_includes SecurityAudit.checks, SecurityAuditChecks::ActionCheck
        assert_empty findings(catalog: catalog_over { get 'reports', to: 'reports#index' })
      end

      # --- guarded actions no Permission Set manages (issue #10) -------------------

      test 'guarded actions no Permission Set manages are listed as refused, per resource and per action' do
        catalog = catalog_over do
          get 'suppliers', to: 'pf_stub_guarded_suppliers#index'
          get 'stub/export', to: 'pf_stub_guarded#export'
          post 'stub/:id/archive', to: 'pf_stub_guarded#archive'
          post 'stub/:id/refresh', to: 'pf_stub_guarded#refresh'
          get 'stub/csv', to: 'pf_stub_guarded#exportCSV'
          get 'stub', to: 'pf_stub_guarded#index'
          post 'stub/:id/merge', to: 'pf_stub_plain#create'
        end
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        found = finding(:unmanaged_actions_refused, catalog: catalog)

        assert_equal :low, found.severity
        assert_equal 'action', found.check
        assert_equal ['Supplier (resource not managed): pf_stub_guarded_suppliers#index',
                      'Customer › archive: pf_stub_guarded#archive',
                      'Customer › exportCSV: pf_stub_guarded#exportCSV (not a valid action key)',
                      'Customer › sync: pf_stub_guarded#refresh'], found.items
        assert_match ':allow', found.detail
        assert_nil finding(:unmanaged_actions_allowed, catalog: catalog)
      end

      test 'under :allow the same actions are listed as open, and none as refused' do
        found = finding(:unmanaged_actions_allowed, catalog: stub_catalog, unconfigured_action_strategy: :allow)

        assert_equal :info, found.severity
        assert_equal ['Customer › archive: pf_stub_guarded#archive', 'Customer › export: pf_stub_guarded#export'], found.items
        assert_nil finding(:unmanaged_actions_refused, catalog: stub_catalog)
      end

      # Reviewer finding: an action managed in one tenant is still refused in
      # every tenant that does not manage it, so each item names those tenants
      # (among the tenants with an active Permission Set).
      test 'with tenancy, an action is listed with the tenants that do not manage it' do
        @config.tenant_model = 'Account'
        home = @set.account_id
        items = -> { ActsAsTenant.without_tenant { finding(:unmanaged_actions_refused, catalog: stub_catalog)&.items } }
        assert_equal ["Customer › archive (not managed in 1 of 1 tenants: #{home}): pf_stub_guarded#archive",
                      "Customer › export (not managed in 1 of 1 tenants: #{home}): pf_stub_guarded#export"], items.call

        muting = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_action(resource: muting, name: 'archive', is_permitted: true)
        other = Account.create!(name: 'Other tenant')
        ActsAsTenant.with_tenant(other) do
          set = create_permission_set(name: 'Elsewhere')
          create_resource_action(resource: create_resource(permission_set: set), name: 'export', is_permitted: true)
        end

        assert_equal ["Customer › archive (not managed in 1 of 2 tenants: #{other.id}): pf_stub_guarded#archive",
                      "Customer › export (not managed in 1 of 2 tenants: #{home}): pf_stub_guarded#export"], items.call

        third = Account.create!(name: 'Third tenant')
        ActsAsTenant.with_tenant(third) { create_permission_set(name: 'Empty') }
        ActsAsTenant.with_tenant(Account.create!(name: 'No sets')) { create_permission_set(name: 'Off', is_active: false) }

        assert_equal ["Customer (resource not managed in 1 of 3 tenants: #{third.id}): pf_stub_guarded#archive, " \
                      'pf_stub_guarded#export',
                      "Customer › archive (not managed in 1 of 3 tenants: #{other.id}): pf_stub_guarded#archive",
                      "Customer › export (not managed in 1 of 3 tenants: #{home}): pf_stub_guarded#export"], items.call
      end

      test 'with tenancy, an action every tenant manages is not listed, and a long tenant list is cut' do
        @config.tenant_model = 'Account'
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'archive', is_permitted: true)
        assert_nil(ActsAsTenant.without_tenant { finding(:unmanaged_actions_refused, catalog: stub_catalog) })

        tenants = Array.new(11) { |i| Account.create!(name: "Tenant #{i}") }
        tenants.each { |tenant| ActsAsTenant.with_tenant(tenant) { create_permission_set(name: 'Empty') } }
        item = ActsAsTenant.without_tenant { finding(:unmanaged_actions_refused, catalog: stub_catalog).items.first }

        assert_equal "Customer (resource not managed in 11 of 12 tenants: #{tenants.first(10).map(&:id).join(', ')}, …): " \
                     'pf_stub_guarded#archive, pf_stub_guarded#export', item
      end

      test 'rows that are not in effect do not manage, and a whole unmanaged resource is listed once' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true, is_active: false)
        @resource.update!(is_active: false)

        assert_equal ['Customer (resource not managed): pf_stub_guarded#archive, pf_stub_guarded#export'],
                     finding(:unmanaged_actions_refused, catalog: stub_catalog).items
      end

      test 'the refused detail says who is refused, from the nil-user settings, and what the audit cannot see' do
        detail = finding(:unmanaged_actions_refused, catalog: stub_catalog).detail

        assert_includes detail, 'to every signed-in user action_guard_bypass does not let through (signed-out requests run them'
        assert_not_includes detail, 'signed-out visitors'
        assert_includes detail, 'unless the controller skips the guard for that action'

        detail = finding(:unmanaged_actions_refused, catalog: stub_catalog, action_guard_nil_user_strategy: :deny).detail
        assert_includes detail, 'to every signed-in user action_guard_bypass does not let through, and to signed-out visitors'
        assert_not_includes detail, 'signed-out requests run them'
      end

      test 'controller actions the catalog could not judge are reported, and the rest still checked' do
        resolver = ->(path, action) { action == 'archive' ? raise('boom') : STUB_RESOLVER.call(path, action) }
        catalog = catalog_over(resolver: resolver) do
          get 'stub/export', to: 'pf_stub_guarded#export'
          post 'stub/:id/archive', to: 'pf_stub_guarded#archive'
        end
        found = finding(:actions_not_checked, catalog: catalog)

        assert_equal :low, found.severity
        assert_equal '1 controller action could not be checked (see the log)', found.title
        assert_equal ['pf_stub_guarded#archive: RuntimeError'], found.items
        assert_equal ['Customer › export: pf_stub_guarded#export'], finding(:unmanaged_actions_refused, catalog: catalog).items
        assert_nil finding(:actions_not_checked, catalog: stub_catalog)
      end

      test 'only controllers that run the guard are listed, with discovery on or off' do
        assert_nil finding(:unmanaged_actions_refused, catalog: stub_catalog(guarded: false))
        assert finding(:unmanaged_actions_refused, catalog: stub_catalog, controller_action_discovery: false)
        assert finding(:unmanaged_actions_refused, catalog: stub_catalog, controller_action_discovery: true)
      end

      test 'the audit reads the app routes for refused actions while discovery is off' do
        action_findings = SecurityAudit.call(configuration: @config, environment: 'test').findings.select { |f| f.check == 'action' }

        assert_equal [:unmanaged_actions_refused], action_findings.map(&:code)
        assert_equal ['Customer › archive: customers#archive', 'Customer › export: customers#export',
                      'Customer › merge: customers/merges#create'], action_findings.first.items
      end

      # --- managed actions nobody is granted --------------------------------------

      test 'a managed action no granting set permits is reported' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        found = finding(:ungranted_actions)

        assert_equal :low, found.severity
        assert_equal 'action', found.check
        assert_equal ['Customer › export: only in Sales'], found.items
      end

      test 'a muting row alone manages an action without permitting it' do
        muting = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_action(resource: muting, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        assert_equal ['Customer › export: only in Contractors, Sales'], finding(:ungranted_actions).items
      end

      test 'an action a granting set permits is not reported' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        managers = create_resource(permission_set: create_permission_set(name: 'Managers'))
        create_resource_action(resource: managers, name: 'export', is_permitted: true)

        assert_nil finding(:ungranted_actions)
      end

      test 'rows that are not in effect neither manage nor permit' do
        off = create_resource_action(resource: @resource, name: 'export', is_permitted: false, is_active: false)
        assert_nil finding(:ungranted_actions)

        off.update!(is_active: true)
        managers = create_permission_set(name: 'Managers', is_active: false)
        create_resource_action(resource: create_resource(permission_set: managers), name: 'export', is_permitted: true)
        assert_equal ['Customer › export: only in Sales'], finding(:ungranted_actions).items

        @resource.update!(is_active: false)
        assert_nil finding(:ungranted_actions)
      end

      test 'managed is judged per tenant' do
        @config.tenant_model = 'Account'
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        other = Account.create!(name: 'Other tenant')
        ActsAsTenant.with_tenant(other) do
          set = create_permission_set(name: 'Elsewhere')
          create_resource_action(resource: create_resource(permission_set: set), name: 'export', is_permitted: true)
        end

        items = ActsAsTenant.without_tenant { finding(:ungranted_actions).items }

        assert_equal ['Customer › export: only in Sales'], items
      end

      # --- configured actions with no controller action ---------------------------

      test 'with discovery on, action rows matching no controller action are listed as a note' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true)
        found = finding(:unlinked_actions, catalog: stub_catalog, controller_action_discovery: true)

        assert_equal :info, found.severity
        assert_equal ['Customer › sync'], found.items
      end

      test 'with discovery off, unlinked rows are not reported' do
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true)

        assert_empty findings(catalog: stub_catalog(guarded: false))
      end

      # --- discovery without the guard --------------------------------------------

      test 'discovery on while no controller includes the guard' do
        catalog = stub_catalog(guarded: false)
        found = finding(:action_guard_missing, catalog: catalog, controller_action_discovery: true)

        assert_equal :low, found.severity
        assert_match 'ControllerActionGuard', found.detail

        create_resource_action(resource: @resource, name: 'merge', is_permitted: true)
        assert_equal :medium, finding(:action_guard_missing, catalog: catalog).severity
      end

      test 'a guarded controller, or discovery off, clears the guard finding' do
        assert_nil finding(:action_guard_missing, catalog: stub_catalog, controller_action_discovery: true)
        assert_nil finding(:action_guard_missing, catalog: stub_catalog(guarded: false), controller_action_discovery: false)
      end

      test 'without an injected catalog the app routes are read' do
        codes = findings(controller_action_discovery: true).map(&:code)

        assert_not_includes codes, :unlinked_actions
        assert_not_includes codes, :ungranted_actions
      end

      # --- managed actions on controllers without the guard -----------------------

      test 'a managed action on an unguarded controller is reported during a partial rollout' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        catalog = stub_catalog
        found = finding(:unguarded_actions, catalog: catalog, controller_action_discovery: true)

        assert_predicate catalog, :any_guarded?
        assert_nil finding(:action_guard_missing, catalog: catalog)
        assert_equal :medium, found.severity
        assert_equal ['Customer › merge: pf_stub_plain#create'], found.items
        assert_match 'ControllerActionGuard', found.detail
      end

      test 'an action is reported with each endpoint that skips or lacks the guard' do
        resolver = ->(path, action) { ['Customer', action] if %w[pf_stub_plain pf_stub_skipping].include?(path) }
        catalog = catalog_over(resolver: resolver) do
          get 'stub/export', to: 'pf_stub_guarded#export'
          get 'plain/export', to: 'pf_stub_plain#export'
          get 'skipping/export', to: 'pf_stub_skipping#export'
          get 'stub/archive', to: 'pf_stub_guarded#archive'
        end
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        create_resource_action(resource: @resource, name: 'archive', is_permitted: true)
        found = finding(:unguarded_actions, catalog: catalog, controller_action_discovery: true)

        assert_equal ['Customer › export: pf_stub_plain#export, pf_stub_skipping#export'], found.items
      end

      test 'an unguarded action is listed once, however many sets manage it' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: true)
        muting = create_resource(permission_set: create_permission_set(name: 'Contractors', is_muting: true))
        create_resource_action(resource: muting, name: 'merge', is_permitted: true)

        assert_equal ['Customer › merge: pf_stub_plain#create'],
                     finding(:unguarded_actions, catalog: stub_catalog, controller_action_discovery: true).items
      end

      test 'only rows in effect that map to a controller action count as unguarded' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: true, is_active: false)
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true)
        off = create_resource(permission_set: create_permission_set(name: 'Old', is_active: false))
        create_resource_action(resource: off, name: 'merge', is_permitted: true)

        assert_nil finding(:unguarded_actions, catalog: stub_catalog, controller_action_discovery: true)
      end

      test 'with discovery off, unguarded controllers are not reported' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: true)

        assert_nil finding(:unguarded_actions, catalog: stub_catalog)
      end

      test 'with no guarded controller at all, both guard findings are reported' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: true)
        codes = findings(catalog: stub_catalog(guarded: false), controller_action_discovery: true).map(&:code)

        assert_includes codes, :action_guard_missing
        assert_includes codes, :unguarded_actions
      end

      # --- names that can never be an action key ----------------------------------

      test 'rows in effect whose name is not a valid action key are reported' do
        create_resource_action(resource: @resource, name: 'Export', is_permitted: false)
        create_resource_action(resource: @resource, name: 'archive ', is_permitted: true)
        create_resource_action(resource: @resource, name: 'sync', is_permitted: true)
        found = finding(:invalid_action_keys)

        assert_equal :low, found.severity
        assert_equal 'action', found.check
        assert_equal ['Sales › Customer › "Export"', 'Sales › Customer › "archive "'], found.items
        assert_match 'can?', found.detail
      end

      test 'an invalid name is reported with or without discovery' do
        create_resource_action(resource: @resource, name: 'Export', is_permitted: true)

        assert_equal ['Sales › Customer › "Export"'], finding(:invalid_action_keys, catalog: stub_catalog(guarded: false)).items
        assert_equal ['Sales › Customer › "Export"'],
                     finding(:invalid_action_keys, catalog: stub_catalog, controller_action_discovery: true).items
      end

      test 'an invalid name that is not in effect is not reported' do
        create_resource_action(resource: @resource, name: 'Export', is_permitted: true, is_active: false)
        off = create_resource(permission_set: create_permission_set(name: 'Old', is_active: false))
        create_resource_action(resource: off, name: 'Archive', is_permitted: true)

        assert_nil finding(:invalid_action_keys)

        @resource.resource_actions.update_all(is_active: true)
        @resource.update!(is_active: false)

        assert_nil finding(:invalid_action_keys)
      end
    end
  end
end
