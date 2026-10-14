# frozen_string_literal: true

require_relative 'integration_support'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module AuditIntegration
    # Events belong to the tenant of the record they are about — whatever
    # tenant is ambient when the change is made — and one tenant's admin
    # never reads another tenant's events. An event written after its
    # transaction ends keeps the tenant it was noticed in.
    class TenancyTest < ActionDispatch::IntegrationTest
      include IntegrationSupport
      include Tenancy::TenancyTestHelper

      NotAuthorized = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @admin = create_user(name: ADMIN_NAME)
        sign_in(@admin)
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        within(@tenant_a) { @set_a = create_permission_set(name: 'A set') }
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'B secret set')
          @assignment_b = create_permission_set_user(user: create_user(name: 'Bea'), permission_set: @set_b)
        end
      end

      # A platform operator's admin, serving every tenant (opted in).
      test 'a change through the admin UI, the API and a service is recorded in the tenant of its record' do
        PermissionForge.configuration.admin_tenantless_access = :allow
        no_tenant!
        patch "#{ROOT}/permission_sets/#{@set_b.id}/apply", params: { pf: { set: { description: 'By the UI' } } }
        patch "#{ROOT}/api/permission_sets/#{@set_b.uuid}", params: { permission_set: { name: 'B renamed' } }, as: :json
        @assignment_b.update_columns(expires_at: 1.day.ago)
        Services::ExpiredAssignmentCleaner.call(actor: @admin)

        names = %w[permission_set.updated assignment.revoked]
        events = AuditEvent.unscoped.where(record_uuid: [@set_b.uuid, @assignment_b.uuid], event: names)
        assert_equal([%w[admin_ui permission_set.updated], %w[api permission_set.updated], %w[service assignment.revoked]],
                     events.order(:id).map { |event| [event.source, event.event] })
        assert_equal [@tenant_b.id], events.map(&:account_id).uniq
      ensure
        PermissionForge.configuration.admin_tenantless_access = :deny
      end

      test 'a change made while another tenant is ambient is still recorded in the record tenant' do
        within(@tenant_a) { patch "#{ROOT}/permission_sets/#{@set_a.id}/apply", params: { pf: { set: { description: 'A' } } } }
        within(@tenant_b) { @set_b.update!(description: 'B') }

        assert_equal @tenant_a.id, tenant_of('permission_set.updated', @set_a)
        assert_equal @tenant_b.id, tenant_of('permission_set.updated', @set_b)
      end

      test 'the API lists and shows only the events of the ambient tenant' do
        within(@tenant_a) { patch "#{ROOT}/api/permission_sets/#{@set_a.uuid}", params: { permission_set: { name: 'A2' } }, as: :json }
        within(@tenant_b) { patch "#{ROOT}/api/permission_sets/#{@set_b.uuid}", params: { permission_set: { name: 'B2' } }, as: :json }
        theirs = AuditEvent.unscoped.find_by!(event: 'permission_set.updated', record_uuid: @set_b.uuid)

        within(@tenant_a) do
          get "#{ROOT}/api/audit_events", params: { per_page: 100 }, as: :json
          uuids = response.parsed_body['data'].map { |row| row['record_uuid'] }
          assert_includes uuids, @set_a.uuid
          assert_not_includes uuids, @set_b.uuid

          get "#{ROOT}/api/audit_events/#{theirs.uuid}", as: :json
          assert_response :not_found
        end
      end

      test 'the admin audit log lists and shows only the events of the ambient tenant' do
        within(@tenant_b) { @set_b.update!(description: 'B') }
        theirs = AuditEvent.unscoped.find_by!(event: 'permission_set.updated', record_uuid: @set_b.uuid)

        within(@tenant_a) do
          @set_a.update!(description: 'A')
          get "#{ROOT}/audit"
          assert_response :ok
          assert_includes response.body, 'A set'
          assert_not_includes response.body, 'B secret set'
          assert_raises(ActionController::RoutingError, ActiveRecord::RecordNotFound) { get "#{ROOT}/audit/#{theirs.uuid}" }
        end
      end

      test 'events written when the transaction ends keep the tenant they were noticed in' do
        enable_basic_auth_with_wrong_password
        rule_denies_customer

        ActiveRecord::Base.transaction do
          within(@tenant_a) do
            get "/pf_audit_probe/customers/#{@denied.id}" # access.denied, stored when the transaction ends
            assert_response :forbidden
            post "#{ROOT}/permission_sets", params: { name: 'x' }, headers: @auth_headers # admin.auth_failed, likewise
            assert_response :unauthorized
          end
          assert_empty AuditEvent.unscoped.where(event: %w[access.denied admin.auth_failed]), 'not written while the transaction is open'
          ActsAsTenant.test_tenant = @tenant_b
        end

        assert_equal @tenant_a.id, AuditEvent.unscoped.where(event: 'access.denied', record_id: @denied.id.to_s).sole.account_id
        assert_equal @tenant_a.id, AuditEvent.unscoped.where(event: 'admin.auth_failed').order(:id).last.account_id
      end

      private

      def tenant_of(event, record)
        AuditEvent.unscoped.where(event: event, record_uuid: record.uuid).order(:id).last.account_id
      end

      def rule_denies_customer
        user = create_user(name: 'Grace')
        within(@tenant_a) do
          resource = create_resource(permission_set: @set_a, name: 'Customer', read_access: true)
          create_permission_set_rule(permission_set: @set_a, resource: resource, include_nulls: false)
          create_permission_set_user(user: user, permission_set: @set_a)
        end
        @denied = create_customer(supplier_id: user.id + 1000)
        sign_in(user)
      end

      def enable_basic_auth_with_wrong_password
        basic_auth!
        @auth_headers = { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials(BASIC_USER, 'wrong') }
      end
    end
  end
end
