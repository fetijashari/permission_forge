require 'test_helper'
require_relative 'tenancy_test_helper'

module PermissionForge
  module Tenancy
    # PermissionForge.with_ambient_tenant pins a tenant for a block (the
    # streamed exports use it to write the body in the action's tenant). It
    # must leave the request-level tenant (ActsAsTenant::Current) exactly as it
    # found it — acts_as_tenant's with_tenant writes the tenant it resolved
    # back, which would shadow test_tenant / a job's "no tenant" afterwards.
    class WithAmbientTenantTest < ActiveSupport::TestCase
      include TenancyTestHelper

      setup do
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
      end

      teardown { ActsAsTenant.current_tenant = nil }

      test 'the block runs in the given tenant' do
        within(@tenant_b) do
          seen = PermissionForge.with_ambient_tenant(@tenant_a) { ActsAsTenant.current_tenant }

          assert_equal @tenant_a, seen
        end
      end

      test 'the request-level tenant is left as it was, not set to the resolved one' do
        within(@tenant_b) do
          ActsAsTenant.current_tenant = nil

          PermissionForge.with_ambient_tenant(@tenant_a) { nil }

          assert_nil ActsAsTenant::Current.current_tenant
          assert_equal @tenant_b, ActsAsTenant.current_tenant
        end
      end

      test 'also when the block raises' do
        within(@tenant_b) do
          ActsAsTenant.current_tenant = nil

          assert_raises(RuntimeError) { PermissionForge.with_ambient_tenant(@tenant_a) { raise 'boom' } }

          assert_nil ActsAsTenant::Current.current_tenant
        end
      end

      test 'a request-level tenant that was set is restored' do
        ActsAsTenant.current_tenant = @tenant_b

        PermissionForge.with_ambient_tenant(@tenant_a) { nil }

        assert_equal @tenant_b, ActsAsTenant::Current.current_tenant
      end
    end
  end
end
