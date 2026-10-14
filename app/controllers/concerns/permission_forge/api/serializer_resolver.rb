module PermissionForge
  module Api
    module SerializerResolver
      extend ActiveSupport::Concern

      private

      def serializer_for(resource_type)
        overrides = PermissionForge.configuration.api_serializer_overrides
        return overrides[resource_type] if overrides.key?(resource_type)

        default_serializers.fetch(resource_type)
      end

      def default_serializers
        {
          permission_set: PermissionForge::Api::Serializers::PermissionSetSerializer,
          resource: PermissionForge::Api::Serializers::ResourceSerializer,
          resource_field: PermissionForge::Api::Serializers::ResourceFieldSerializer,
          resource_action: PermissionForge::Api::Serializers::ResourceActionSerializer,
          permission_set_rule: PermissionForge::Api::Serializers::PermissionSetRuleSerializer,
          permission_set_user: PermissionForge::Api::Serializers::PermissionSetUserSerializer,
          permission_set_group: PermissionForge::Api::Serializers::PermissionSetGroupSerializer,
          permission_set_group_user: PermissionForge::Api::Serializers::PermissionSetGroupUserSerializer,
          audit_event: PermissionForge::Api::Serializers::AuditEventSerializer
        }
      end
    end
  end
end
