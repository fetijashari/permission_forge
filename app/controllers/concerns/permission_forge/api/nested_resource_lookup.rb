module PermissionForge
  module Api
    module NestedResourceLookup
      extend ActiveSupport::Concern

      private

      def set_resource
        @permission_set = find_record(PermissionForge::PermissionSet, :permission_set_identifier)
        @resource = find_record(@permission_set.resources, :resource_identifier)
      end

      def find_nested_record(scope)
        find_record(scope)
      end
    end
  end
end
