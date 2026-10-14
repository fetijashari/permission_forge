# frozen_string_literal: true

module PermissionForge
  module Services
    # @api private
    module Concerns
      # A housekeeping service run with no tenant ambient (a rake task, a
      # console, a platform job) works on every tenant's rows; with a tenant
      # ambient, on that tenant's only.
      #
      # #across_tenants lifts acts_as_tenant's scope for the tenant-less run,
      # as PermissionedUser's destroy and PermissionCacheClearer do, so
      # `require_tenant = true` does not refuse it with NoTenantSet; with a
      # tenant ambient, or tenancy off, the block runs as it is. No hard
      # dependency on acts_as_tenant: without it there is nothing to lift.
      #
      # #record_per_tenant writes a run's summary event the way audit.purged
      # and cache.cleared are written: with a tenant ambient, once (in it);
      # tenant-less, once in each tenant the run touched, with that tenant's
      # rows, plus the total without a tenant — each marked across_tenants —
      # so every tenant's auditors see what was done in their tenant.
      module AcrossTenants
        # One summary event of a run over `rows`; `data` builds the event's
        # data from the rows it covers.
        Summary = Struct.new(:event, :rows, :payload, :data) do
          def record(covered = rows, tenant_id: nil, more: {})
            PermissionForge::Audit.record(event, **payload, tenant_id: tenant_id, data: data.call(covered).merge(more))
          end

          # In each tenant with its rows, then the total without a tenant.
          def record_per_tenant(column)
            by_tenant = rows.select { |row| row.has_attribute?(column) && !row[column].nil? }.group_by { |row| row[column] }
            by_tenant.each { |tenant_id, tenant_rows| record(tenant_rows, tenant_id: tenant_id, more: { 'across_tenants' => true }) }
            record(more: { 'across_tenants' => true, 'tenants' => by_tenant.size })
          end
        end

        private

        def across_tenants(&)
          return yield unless tenantless_run?

          ::ActsAsTenant.without_tenant(&)
        end

        # Tenancy is on and no tenant is ambient.
        def tenantless_run?
          PermissionForge.configuration.tenant_enabled? && defined?(::ActsAsTenant) && PermissionForge.ambient_tenant.nil?
        end

        # @param event [String] the summary event
        # @param rows [Array<ActiveRecord::Base>] the rows the run changed
        # @param payload [Hash] more of Audit.record's payload (subject_user_id: …)
        # @yieldparam rows [Array<ActiveRecord::Base>] the rows of one tenant, or all of them
        # @yieldreturn [Hash] the event's data for those rows
        def record_per_tenant(event, rows, **payload, &data)
          summary = Summary.new(event, rows, payload, data)
          return summary.record unless tenantless_run?

          summary.record_per_tenant(tenant_column)
        end

        def tenant_column
          PermissionForge.configuration.resolved_tenant_column.to_s
        end
      end
    end
  end
end
