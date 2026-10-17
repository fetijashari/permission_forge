# frozen_string_literal: true

module PermissionForge
  module Admin
    # Every Permission Set containing a resource — or, for a
    # single-table-inheritance subclass, one of the bases its records answer
    # to (ResourceChain: a base's field row reaches the subclass) — with one
    # field's row there (granting sets first, then by name) and the set's
    # people count. Backs the field drawer's "In other sets" list and "Who can see …?".
    class FieldAcrossSets
      # @return [Array<Hash>] { resource:, set:, field: (ResourceField or nil), people:, in_effect: }
      #   in_effect is whether the row (or, without a row, the resource) counts
      #   right now, as in ActionAcrossSets#rows.
      def self.call(resource_name, key) = new(resource_name, key).call

      def initialize(resource_name, key)
        @resource_name = resource_name
        @key = key
      end

      def call
        resources.map do |resource|
          field = field_in(resource)
          { resource: resource, set: resource.permission_set, field: field, people: people_count(resource),
            in_effect: resource.in_effect? && (field.nil? || field.is_active) }
        end
      end

      private

      def resources
        names = PermissionForge::ResourceChain.names_for(@resource_name).map(&:to_s)
        PermissionForge::Resource.where(name: names).includes(:resource_fields, permission_set: :resources)
                                 .sort_by { |resource| sort_key(resource.permission_set) }
      end

      def sort_key(permission_set)
        [permission_set.is_muting ? 1 : 0, permission_set.name]
      end

      def field_in(resource)
        resource.resource_fields.find { |field| field.name == @key }
      end

      def people_count(resource)
        people_counts.fetch(resource.permission_set_id, 0)
      end

      def people_counts
        @people_counts ||= PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
      end
    end
  end
end
