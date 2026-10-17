# frozen_string_literal: true

# A negative fixture for CacheReportGuardTest (R2 review, P1-5): a service
# that measures one invalidation through Cache::Report and has another
# method that does not. Through 0.15.0-rc the guard exempted the whole file
# once it mentioned Cache::Report. Never required; scanned by that test only.
module MeasuresOneMethod
  def self.call(user)
    PermissionForge::Cache::Report.of { forget(user) }
  end

  # Called only from the measured block: measured.
  def self.forget(user)
    user.invalidate_permissions
  end

  def self.unmeasured_probe = PermissionForge.configuration.user_model.find_each(&:invalidate_permissions)
end
