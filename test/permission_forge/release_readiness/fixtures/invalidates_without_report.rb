# frozen_string_literal: true

# A negative fixture for CacheReportGuardTest: a service that invalidates a
# user's cached permissions without measuring it through Cache::Report.
# Never required; scanned by that test only.
module InvalidatesWithoutReport
  def self.call(user)
    user.invalidate_permissions
  end
end
