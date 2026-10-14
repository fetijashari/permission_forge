# frozen_string_literal: true

module PermissionForge
  module Admin
    # One resource's action rows in every Permission Set that contains the
    # resource: who manages an action and who permits it. Loaded on first use,
    # once for all of the resource's action keys. Backs the Actions tab, the
    # action drawers ("Across all Permission Sets") and the "Review and save"
    # sentences.
    #
    # "Managed" means what ControllerActions::ManagedIndex means: a row in
    # effect (ResourceAction#in_effect?) in any Permission Set, granting or
    # muting. This reads the database, not the index, so it also knows *which*
    # sets.
    #
    # @example
    #   across = ActionAcrossSets.new('Customer')
    #   across.managed?('export')         # => true
    #   across.permitting_sets('export')  # => [#<PermissionSet name: "Sales rep">]
    class ActionAcrossSets
      def initialize(resource_name)
        @resource_name = resource_name.to_s
      end

      # @param key [String, Symbol] action key (e.g. 'export')
      # @return [Array<Hash>] { resource:, set:, action: (ResourceAction or nil), in_effect: }
      #   for every set containing the resource — granting sets first, then by
      #   name. in_effect is whether the row (or, without a row, the resource)
      #   counts right now.
      def rows(key)
        name = key.to_s
        resources.map do |resource|
          action = action_in(resource, name)
          { resource: resource, set: resource.permission_set, action: action, in_effect: (action || resource).in_effect? }
        end
      end

      # @return [Boolean] whether any Permission Set manages the action right now
      def managed?(key)
        live_rows.key?(key.to_s)
      end

      # @return [Array<PermissionForge::PermissionSet>] granting sets whose row
      #   permits the action right now
      def permitting_sets(key)
        live_rows.fetch(key.to_s, []).filter_map do |permission_set, action|
          permission_set if action.is_permitted && !permission_set.is_muting
        end
      end

      private

      def resources
        @resources ||= PermissionForge::Resource.where(name: @resource_name).includes(:permission_set, :resource_actions)
                                                .sort_by { |resource| sort_key(resource.permission_set) }
      end

      def sort_key(permission_set)
        [permission_set.is_muting ? 1 : 0, permission_set.name]
      end

      # { 'export' => [[PermissionSet, ResourceAction], ...] } — the rows in effect.
      def live_rows
        @live_rows ||= resources.each_with_object({}) do |resource, index|
          resource.resource_actions.select(&:in_effect?).each do |action|
            (index[action.name] ||= []) << [resource.permission_set, action]
          end
        end
      end

      def action_in(resource, name)
        resource.resource_actions.find { |action| action.name == name }
      end
    end
  end
end
