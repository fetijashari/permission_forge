# frozen_string_literal: true

module PermissionForge
  module Api
    class ResourceFieldsController < BaseController
      include CrudActions
      include NestedResourceLookup

      before_action :set_resource
      before_action :set_field, only: %i[show update destroy]

      private

      def collection_scope = @resource.resource_fields
      def current_record = @field
      def serializer_type = :resource_field

      def set_field
        @field = find_nested_record(@resource.resource_fields)
      end

      def record_params
        pf_record_attributes(:resource_field, PermissionForge::ResourceField,
                             :name, :label, :description, :is_active, :is_editable,
                             :read_access, :edit_access, :mask_access, :mask_strategy)
      end
    end
  end
end
