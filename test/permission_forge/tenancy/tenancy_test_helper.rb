# Tenant switching for the tenancy suite. Uses ActsAsTenant.test_tenant rather
# than ActsAsTenant.with_tenant: with_tenant writes the *resolved* tenant back
# into ActsAsTenant::Current on exit, which then shadows test_tenant for the
# rest of the test (and survives request boundaries in integration tests), so
# "no tenant at all" could never be reached afterwards.
module PermissionForge
  module Tenancy
    module TenancyTestHelper
      private

      def within(tenant)
        previous = ActsAsTenant.test_tenant
        ActsAsTenant.test_tenant = tenant
        yield
      ensure
        ActsAsTenant.test_tenant = previous
      end

      # A job or console with no tenant: clears the request-level (Current) and
      # the test-level tenant.
      def no_tenant!
        ActsAsTenant.current_tenant = nil
        ActsAsTenant.test_tenant = nil
      end
    end
  end
end
