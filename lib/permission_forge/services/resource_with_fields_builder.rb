module PermissionForge
  module Services
    # Creates a Resource with full CRUD access and its generated fields, all or nothing.
    #
    # @api public
    class ResourceWithFieldsBuilder
      # @param permission_set [PermissionSet]
      # @param resource_name [String] the model name
      # @return [Resource]
      def self.call(permission_set:, resource_name:)
        new(permission_set, resource_name).call
      end

      def initialize(permission_set, resource_name)
        @permission_set = permission_set
        @resource_name = resource_name
      end

      # The resource and its fields are created all or nothing, under one
      # audit correlation id (an enclosing block's, if any).
      def call
        PermissionForge::Audit.correlate do
          PermissionForge::Resource.transaction do
            resource = create_resource
            ResourceFieldGenerator.call(resource: resource, grant_all: true)
            resource
          end
        end
      end

      private

      def create_resource
        PermissionForge::Resource.create!(
          name: @resource_name,
          permission_set: @permission_set,
          read_access: true,
          create_access: true,
          edit_access: true,
          delete_access: true,
          is_active: true,
          is_editable: true
        )
      end
    end
  end
end
