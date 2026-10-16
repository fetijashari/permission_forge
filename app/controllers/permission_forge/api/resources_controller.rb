# frozen_string_literal: true

module PermissionForge
  module Api
    class ResourcesController < BaseController
      include CrudActions

      before_action :set_permission_set
      before_action :set_resource, only: %i[show update destroy generate_fields]

      # Creates a field row for every unconfigured column: with grant_all,
      # readable and editable, unmasked; without it, no access (under
      # gdpr_defaults, personal-data columns readable and masked). It passes
      # the same gates as the admin UI's "Sync fields": the authorization
      # hook, then the lock on the resource and its set. grant_all is read
      # by ParamShapes#pf_boolean_param (true, "true", 1, "1"; absent, false,
      # "false", 0, "0"): anything else is a 422 keyed by grant_all, never
      # fields without edit. A Resource named after no model this app can
      # load (PermissionForge::ModelLookup: `Kernel`, a model without its
      # table) has no columns: a 422 keyed by name.
      def generate_fields
        guard_mutation!(:generate_fields, @resource)
        refuse_no_model unless performed?
        return if performed?

        fields = PermissionForge::Services::ResourceFieldGenerator.call(
          resource: @resource,
          grant_all: pf_boolean_param(:grant_all)
        )
        data = PermissionForge::Api::Serializers::ResourceFieldSerializer.collection(fields)
        render json: { data: data }, status: :created
      rescue ParamShapes::InvalidParam
        raise # rendered by BaseController like every input error
      rescue StandardError => e
        # Log the internal detail; return a generic message so model/column names
        # and adapter errors are not leaked to API clients.
        Rails.logger.error("[PermissionForge] generate_fields failed for #{@resource&.name}: #{e.class}: #{e.message}")
        render_unprocessable('base' => [I18n.t('permission_forge.api.errors.field_generation_failed')])
      end

      private

      def collection_scope = @permission_set.resources
      def current_record = @resource
      def serializer_type = :resource

      # 422 on name for a Resource named after no model this app can load.
      def refuse_no_model
        return if PermissionForge::ModelLookup.model?(@resource.name)

        render_unprocessable('name' => [I18n.t('permission_forge.api.errors.resource_names_no_model')])
      end

      def set_permission_set
        @permission_set = find_record(PermissionForge::PermissionSet, :permission_set_identifier)
      end

      def set_resource
        @resource = find_record(@permission_set.resources)
      end

      def record_params
        pf_require_hash(:resource).permit(
          :name, :description, :is_active, :is_editable,
          :read_access, :create_access, :edit_access, :delete_access,
          :view_all, :modify_all
        )
      end
    end
  end
end
