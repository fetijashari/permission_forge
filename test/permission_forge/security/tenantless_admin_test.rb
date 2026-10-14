# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Security
    # With tenancy configured, a request to the admin screens or the admin
    # API that arrives with no current tenant is refused (403, recorded):
    # with no tenant acts_as_tenant scopes nothing, so it would read and
    # change every tenant's Permission Sets, assignments and audit log.
    # config.admin_tenantless_access = :allow is the opt-out.
    class TenantlessAdminTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      include PermissionForge::Tenancy::TenancyTestHelper

      ROOT = '/permission_forge'

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @tenant_a = Account.create!(name: 'Tenant A')
        within(@tenant_a) { @set_a = create_permission_set(name: 'Alphaset') }
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
        ActsAsTenant.configuration.require_tenant = false
        PermissionForge.configuration.admin_tenantless_access = :deny
      end

      def refusals(event)
        PermissionForge::AuditEvent.unscoped.where(event: event).select { |e| e.data['reason'] == 'tenant_missing' }.size
      end

      test 'the default refuses tenant-less access, as the install initializer says' do
        assert_equal :deny, Configuration.new.admin_tenantless_access
        assert_includes render_install_template('initializer.rb.tt', tenant_model: 'Account'),
                        '# config.admin_tenantless_access = :deny'
      end

      # --- admin screens ----------------------------------------------------------

      test 'an admin page with no tenant is refused and recorded' do
        no_tenant!

        assert_difference -> { refusals('admin.auth_failed') }, 1 do
          get "#{ROOT}/permission_sets"
        end
        assert_response :forbidden
        assert_equal I18n.t('permission_forge.errors.tenant_required'), response.body
        assert_not_includes response.body, 'Alphaset'
      end

      test 'an admin change with no tenant is refused and changes nothing' do
        no_tenant!

        patch "#{ROOT}/permission_sets/#{@set_a.id}/apply", params: { pf: { set: { name: 'Edited by nobody' } } }

        assert_response :forbidden
        assert_equal 'Alphaset', PermissionForge::PermissionSet.unscoped.find(@set_a.id).name
      end

      test 'the refusal holds when acts_as_tenant requires a tenant' do
        no_tenant!
        ActsAsTenant.configuration.require_tenant = true

        get "#{ROOT}/permission_sets"

        assert_response :forbidden
      end

      test 'an admin page with a tenant is served' do
        ActsAsTenant.test_tenant = @tenant_a

        get "#{ROOT}/permission_sets"

        assert_response :ok
        assert_includes response.body, 'Alphaset'
      end

      test 'under the opt-out a tenant-less create is refused as invalid, never stored without a tenant' do
        PermissionForge.configuration.admin_tenantless_access = :allow
        no_tenant!

        assert_no_difference -> { PermissionForge::PermissionSet.unscoped.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'Nobody' } }
        end
        assert_response :unprocessable_entity
        assert response.parsed_body.dig('error', 'messages', 'account').present?
      end

      test 'the opt-out serves tenant-less admin pages' do
        PermissionForge.configuration.admin_tenantless_access = :allow
        no_tenant!

        get "#{ROOT}/permission_sets"

        assert_response :ok
      end

      test 'an unknown setting is refused when set, and the requests stay refused' do
        assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge.configuration.admin_tenantless_access = 'yes please'
        end
        no_tenant!

        get "#{ROOT}/permission_sets"

        assert_response :forbidden
      end

      test 'without tenancy no tenant is needed' do
        PermissionForge.configuration.tenant_model = nil
        no_tenant!

        get "#{ROOT}/permission_sets"

        assert_response :ok
      end

      test 'sign-in comes first: an unauthenticated request is still a 401' do
        PermissionForge.configuration.http_basic_auth_enabled = true
        no_tenant!

        get "#{ROOT}/permission_sets"

        assert_response :unauthorized
      end

      test 'the admin stylesheet is served without a tenant' do
        no_tenant!

        get "#{ROOT}/pf-assets/pf_admin.css"

        assert_response :ok
      end

      # --- admin API --------------------------------------------------------------------

      test 'an API read with no tenant is refused and recorded' do
        no_tenant!

        assert_difference -> { refusals('api.auth_failed') }, 1 do
          get "#{ROOT}/api/permission_sets"
        end
        assert_response :forbidden
        assert_equal I18n.t('permission_forge.api.errors.tenant_required'), response.parsed_body.dig('error', 'messages')
      end

      test 'an API change with no tenant is refused' do
        no_tenant!

        assert_no_difference -> { PermissionForge::PermissionSet.unscoped.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'Nobody' } }
        end
        assert_response :forbidden
      end

      test 'the API is served with a tenant, or tenant-less under the opt-out' do
        ActsAsTenant.test_tenant = @tenant_a
        get "#{ROOT}/api/permission_sets"
        assert_response :ok

        PermissionForge.configuration.admin_tenantless_access = :allow
        no_tenant!
        get "#{ROOT}/api/permission_sets"
        assert_response :ok
      end

      # --- posture checks -------------------------------------------------------------

      test 'the security audit flags tenancy with the default base controllers' do
        config = Configuration.new
        config.tenant_model = 'Account'

        finding = tenancy_finding(config)
        assert_equal :medium, finding.severity

        config.admin_tenantless_access = :allow
        assert_equal :high, tenancy_finding(config).severity

        config.base_controller_class = '::ApplicationController'
        assert_nil tenancy_finding(config), 'the API is off: its base controller does not count'

        config.api_enabled = true
        assert_equal :high, tenancy_finding(config).severity, 'the API base controller is still the default'

        config.api_base_controller_class = '::ApplicationController'
        assert_nil tenancy_finding(config)
      end

      test 'the boot warning names the default base controllers when tenancy is on' do
        config = Configuration.new
        config.tenant_model = 'Account'
        config.api_enabled = true

        warning = config.tenantless_admin_warning
        assert_match(/base_controller_class and api_base_controller_class/, warning)
        assert_match(/refused/, warning)

        config.tenant_model = nil
        assert_nil config.tenantless_admin_warning
      end

      private

      def tenancy_finding(config)
        report = PermissionForge::Services::SecurityAudit.call(configuration: config, environment: 'test',
                                                               checks: [PermissionForge::Services::SecurityAuditChecks::ConfigCheck])
        report.findings.find { |f| f.code == :tenantless_admin }
      end
    end
  end
end
