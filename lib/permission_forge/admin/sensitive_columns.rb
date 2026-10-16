# frozen_string_literal: true

module PermissionForge
  module Admin
    # PermissionForge::Admin::SensitiveColumns moved to
    # PermissionForge::SensitiveColumns in 0.15.0 (one matcher for the admin,
    # the field generator, the GDPR audit and the boot warning). The old name
    # answers with the new class and a deprecation warning
    # (PermissionForge.deprecator) until the horizon; a lexical
    # `SensitiveColumns` inside the Admin namespace resolves to the new
    # class directly.
    include ActiveSupport::Deprecation::DeprecatedConstantAccessor

    deprecate_constant 'SensitiveColumns', 'PermissionForge::SensitiveColumns', deprecator: PermissionForge.deprecator
  end
end
