# frozen_string_literal: true

module PermissionForge
  # The model classes (PermissionForge::MODEL_NAMES), for the tests that go
  # through every model.
  module TestModels
    module_function

    # @return [Array<Class>] every model, loaded on demand
    def all
      PermissionForge::MODEL_NAMES.map { |name| PermissionForge.const_get(name) }
    end

    # The suite turns tenancy on after boot (test_helper), and the boot
    # checks have loaded a model by then: applies the tenant scope to every
    # model (idempotent). A booted application needs no call — each model
    # scopes itself as it loads.
    def apply_tenant_scoping!
      return unless PermissionForge.configuration.tenant_enabled?

      PermissionForge::BootChecks.ensure_tenancy_gem!(PermissionForge.configuration)
      all.each(&:apply_tenant_scoping!)
    end
  end
end
