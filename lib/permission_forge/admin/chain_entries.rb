# frozen_string_literal: true

module PermissionForge
  module Admin
    # Whether a Permission Set holds more than one Resource of a
    # single-table-inheritance chain (ResourceChain: a base and a subclass on
    # its table) — then a row that names the set about one of them says which
    # ("Sales rep · VipCustomer", LabelsHelper#pf_set_entry_name): the field
    # drawer's "Across all Permission Sets" and a person's effective access
    # showed two rows "Sales rep" with different levels and no way to tell
    # them apart (field test round 7, B#35). Every Resource row of the set
    # counts, turned off or not: it is about naming, not about access.
    #
    # @example
    #   ChainEntries.several?(set, %w[VipCustomer Customer]) # => true when the set has both Resources
    #
    # @api private
    module ChainEntries
      # @param permission_set [PermissionSet]
      # @param names [Array<String, Symbol>] the Resource names of the chain
      # @return [Boolean]
      def self.several?(permission_set, names)
        names = names.map(&:to_s)
        return false if names.size < 2

        permission_set.resources.count { |resource| names.include?(resource.name) } > 1
      end
    end
  end
end
