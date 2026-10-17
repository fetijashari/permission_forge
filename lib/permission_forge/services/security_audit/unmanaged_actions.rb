# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # The guarded controller actions no Permission Set manages, as the
      # ActionCheck lists them: the ones the guard hands to
      # unconfigured_action_strategy (ControllerActions::Authorizer rows 4 and 8).
      #
      # "Managed" is per tenant (ManagedIndex): with tenancy, an action is
      # listed with the tenants that do not manage it, among those that have
      # an active Permission Set.
      #
      #   UnmanagedActions.new(entries: catalog.mapped_entries, managed: { nil => { 'Customer' => Set['export'] } }).items
      #   # => ["Invoice (resource not managed): invoices#index, invoices#show",
      #   #     "Customer › archive: customers#archive"]
      #   # with tenants: [3, 4, 9]
      #   # => ["Customer (resource not managed in 2 of 3 tenants: 3, 9): customers#index, customers#archive",
      #   #     "Customer › archive (not managed in 1 of 3 tenants: 4): customers#archive"]
      class UnmanagedActions
        # Tenant ids named in one item; the count says how many there are.
        TENANT_LIMIT = 10

        class << self
          # Reads what is managed in each tenant from the rows in effect
          # (Resource.in_effect, ResourceAction.in_effect: what ManagedIndex
          # reads, for every tenant at once). The tenants judged are those
          # with an active Permission Set; with none, every action is listed
          # without a tenant.
          #
          # @return [UnmanagedActions]
          def build(entries:, configuration:)
            tenant = configuration.resolved_tenant_column
            new(entries: entries, managed: managed_index(tenant), tenants: tenant && tenants_with_sets(tenant))
          end

          # Who the guard refuses them to: signed-out requests follow
          # action_guard_nil_user_strategy (else nil_user_strategy) before the
          # strategy is asked.
          #
          # @return [String]
          def refused_to(configuration)
            signed_out = if configuration.action_guard_nil_user_bypass?
                           ' (signed-out requests run them: action_guard_nil_user_strategy, else nil_user_strategy, is :bypass)'
                         else
                           ', and to signed-out visitors'
                         end
            "to every signed-in user action_guard_bypass does not let through#{signed_out}"
          end

          private

          # A resource row is [tenant, name], an action row [tenant, name, key].
          def managed_index(tenant)
            (resource_rows(tenant) + action_rows(tenant)).each_with_object({}) do |(id, name, key), index|
              keys = ((index[id] ||= {})[name] ||= Set.new)
              keys << key if key
            end
          end

          def resource_rows(tenant)
            PermissionForge::Resource.in_effect.distinct.pluck(tenant_of(PermissionForge::Resource, tenant), resource_name)
          end

          def action_rows(tenant)
            PermissionForge::ResourceAction.in_effect.distinct
                                           .pluck(tenant_of(PermissionForge::Resource, tenant), resource_name,
                                                  PermissionForge::ResourceAction.arel_table[:name])
          end

          def resource_name = PermissionForge::Resource.arel_table[:name]

          def tenants_with_sets(tenant)
            ids = PermissionForge::PermissionSet.active.distinct.pluck(tenant_of(PermissionForge::PermissionSet, tenant))
            (ids.compact.sort + ids.select(&:nil?)).presence
          end

          def tenant_of(model, tenant)
            tenant ? model.arel_table[tenant] : Arel.sql('NULL')
          end
        end

        # @param entries [Array<PermissionForge::Admin::ControllerCatalog::Entry>]
        #   every mapped controller action (ControllerCatalog#mapped_entries)
        # @param managed [Hash{Object => Hash{String => Set<String>}}] tenant id
        #   (nil without tenancy) => the managed action keys of each resource
        #   some Permission Set of that tenant manages (ManagedIndex's shape)
        # @param tenants [Array, nil] the tenants to judge, nil without tenancy
        def initialize(entries:, managed:, tenants: nil)
          @entries = entries.select(&:guarded?)
          @managed = managed
          @tenants = tenants
        end

        # @return [Array<String>] one item per resource some tenant does not
        #   manage, then one per custom action of a resource a tenant manages
        #   without managing the action
        def items
          resource_items + action_items
        end

        private

        def judged = @tenants || [nil]

        def index(tenant) = @managed.fetch(tenant, {})

        def resource_items
          @entries.group_by(&:resource).filter_map do |resource, group|
            missing = judged.reject { |tenant| index(tenant).key?(resource) }
            "#{resource} (resource not managed#{where(missing)}): #{endpoints(group)}" unless missing.empty?
          end
        end

        # An action whose name is not a valid key can never get a row: it says so.
        def action_items
          @entries.reject(&:crud?).group_by(&:pair).filter_map do |(resource, key), group|
            missing = judged.select { |tenant| index(tenant).fetch(resource, nil)&.exclude?(key) }
            action_item(group, missing) unless missing.empty?
          end
        end

        def action_item(group, missing)
          first = group.first
          note = ' (not a valid action key)' unless first.manageable?
          "#{first.resource} › #{first.key}#{" (not managed#{where(missing)})" if @tenants}: #{endpoints(group)}#{note}"
        end

        # " in 2 of 5 tenants: 3, 9", or nothing without tenancy.
        def where(missing)
          return '' unless @tenants

          shown = missing.first(TENANT_LIMIT).map { |tenant| tenant_label(tenant) }
          " in #{missing.size} of #{@tenants.size} tenants: #{shown.join(', ')}#{', …' if missing.size > TENANT_LIMIT}"
        end

        def tenant_label(tenant) = tenant.nil? ? 'none' : tenant.to_s

        def endpoints(group)
          group.map(&:endpoint).uniq.join(', ')
        end
      end
    end
  end
end
