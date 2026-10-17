# frozen_string_literal: true

module PermissionForge
  module Admin
    # Creates Permission Sets from the admin UI: fresh, started from another
    # set, or duplicated. Copies are deep (resources, fields, actions, rules,
    # conditions) — never assignments — with every copied record unlocked.
    module PermissionSetFactory
      # @param attrs [Hash] name:, is_muting:, permission_set_group:
      # @param source [PermissionSet, nil] set to start from
      def self.create(attrs, source: nil)
        return clone_unlocked(source, attrs.merge(is_active: true)) if source

        PermissionForge::PermissionSet.create!(attrs.merge(is_active: true, is_editable: true))
      end

      # An editable copy, named "<name> (copy)" (numbered when taken) unless
      # a name is given. A source in a locked Permission Set Group is copied
      # outside it: the copy would change the locked group's list of sets.
      def self.duplicate(source, name: PermissionForge::PermissionSet.copy_name(source.name))
        attrs = { name: name, is_editable: true }
        attrs[:permission_set_group] = nil if EditableLock.locked?(source.permission_set_group)
        clone_unlocked(source, attrs)
      end

      # Case-insensitive, in the current tenant (PermissionSet.name_taken?).
      def self.name_taken?(name) = PermissionForge::PermissionSet.name_taken?(name)

      # `base`, else "`base` 2", "`base` 3", ... — the first free name.
      def self.unique_name(base) = PermissionForge::PermissionSet.unique_name(base)

      # Every copied row is created unlocked, so its create event holds the
      # state it has (no second, unaudited write).
      def self.clone_unlocked(source, attrs)
        PermissionForge::Services::PermissionSetCloner.call(permission_set: source, attrs: attrs.merge(is_editable: true), unlock: true)
      end
    end
  end
end
