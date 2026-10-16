# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Conditionally includes acts_as_tenant on PermissionForge models
    # when `config.tenant_model` is set and the acts_as_tenant gem is available.
    #
    # All permission data is strictly scoped to the current tenant.
    # Cross-tenant user sharing is supported: the same user can be assigned
    # to permission sets in multiple tenants, each producing a separate cached hash.
    #
    # @example Enable in initializer
    #   config.tenant_model = 'Account'  # enables multi-tenancy
    #   config.tenant_column = :account_id  # optional, inferred from model
    #
    # @api private
    module HasTenantScoping
      extend ActiveSupport::Concern

      class_methods do
        # Declares the tenant association and default scope on the including
        # model, on the configured column. Each model calls it as its class
        # body loads — after the host's config/initializers (the models are
        # autoloaded), and after its own macros, so acts_as_tenant's callbacks
        # keep running after the model's own; a code reload declares it again.
        # Idempotent: acts_as_tenant adds a default_scope on every call, so
        # applying twice (the class body plus a host, or the test suite,
        # calling it by hand) would filter the tenant twice.
        def apply_tenant_scoping!
          config = PermissionForge.configuration
          return unless config.tenant_enabled? && defined?(ActsAsTenant)
          return if tenant_scoping_applied?

          acts_as_tenant config.tenant_association_name,
                         foreign_key: config.resolved_tenant_column,
                         class_name: config.tenant_model,
                         **tenant_scoping_options
          @pf_tenant_model = config.tenant_model.to_s
        end

        # Extra acts_as_tenant options of the including model. A permission
        # row needs a tenant whatever the host's belongs_to_required_by_default
        # says (the models load after the host's initializers, where that
        # setting may be anything); a model whose rows may belong to none (an
        # audit event of a cross-tenant task) overrides this with
        # `{ optional: true }`.
        def tenant_scoping_options
          { optional: false }
        end

        # The tenant model this class was scoped on as it loaded; nil while
        # it is not scoped (ModelBindings compares it with the configuration).
        #
        # @return [String, nil]
        def tenant_scoping_model
          @pf_tenant_model if tenant_scoping_applied?
        end

        # acts_as_tenant defines scoped_by_tenant? on the class once applied.
        def tenant_scoping_applied?
          respond_to?(:scoped_by_tenant?)
        end

        # The rows of one tenant whatever tenant is ambient, together with the
        # rows that have no tenant (written before tenancy was switched on).
        # No tenant id means every row — and so does a table that has no
        # tenant column (an install that predates it): its rows cannot be told
        # apart, and a lookup that raised would invalidate nobody.
        # Built without ActsAsTenant.with_tenant, which writes the tenant it
        # resolved back into the request-level one.
        #
        # @param tenant_id [Object, nil]
        # @return [ActiveRecord::Relation]
        def of_tenant(tenant_id)
          config = PermissionForge.configuration
          return all unless config.tenant_enabled? && tenant_scoping_applied?

          column = config.resolved_tenant_column
          return unscoped if tenant_id.nil? || !PermissionForge::SchemaRead.column?(self, column.to_s, ignored: false)

          unscoped.where(column => [tenant_id, nil])
        end
      end
    end
  end
end
