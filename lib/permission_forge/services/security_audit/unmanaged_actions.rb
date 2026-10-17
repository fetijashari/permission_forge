# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # The guarded controller actions no Permission Set manages, as the
      # ActionCheck lists them: the ones the guard hands to
      # unconfigured_action_strategy (ControllerActions::Authorizer rows 4 and 8).
      #
      #   UnmanagedActions.new(entries: catalog.mapped_entries, managed: { 'Customer' => Set['export'] }).items
      #   # => ["Invoice (resource not managed): invoices#index, invoices#show",
      #   #     "Customer › archive: customers#archive"]
      class UnmanagedActions
        # @param entries [Array<PermissionForge::Admin::ControllerCatalog::Entry>]
        #   every mapped controller action (ControllerCatalog#mapped_entries)
        # @param managed [Hash{String => Set<String>}] the managed action keys of
        #   each resource some Permission Set manages (ManagedIndex's shape)
        def initialize(entries:, managed:)
          @entries = entries.select(&:guarded?)
          @managed = managed
        end

        # @return [Array<String>] one item per resource no set manages, then one
        #   per custom action of a managed resource that no set manages
        def items
          unmanaged, managed = @entries.partition { |entry| !@managed.key?(entry.resource) }
          resource_items(unmanaged) + action_items(managed.reject { |entry| entry.crud? || managed_pairs.include?(entry.pair) })
        end

        private

        # [['Customer', 'export'], ...]
        def managed_pairs
          @managed_pairs ||= @managed.flat_map { |resource, keys| keys.map { |key| [resource, key] } }.to_set
        end

        def resource_items(entries)
          entries.group_by(&:resource).map do |resource, group|
            "#{resource} (resource not managed): #{endpoints(group)}"
          end
        end

        # An action whose name is not a valid key can never get a row: it says so.
        def action_items(entries)
          entries.group_by(&:pair).map do |(resource, key), group|
            note = ' (not a valid action key)' unless group.first.manageable?
            "#{resource} › #{key}: #{endpoints(group)}#{note}"
          end
        end

        def endpoints(group)
          group.map(&:endpoint).uniq.join(', ')
        end
      end
    end
  end
end
