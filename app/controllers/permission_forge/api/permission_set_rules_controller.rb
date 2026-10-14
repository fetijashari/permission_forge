# frozen_string_literal: true

module PermissionForge
  module Api
    class PermissionSetRulesController < BaseController
      include CrudActions
      include NestedResourceLookup

      before_action :set_resource
      before_action :set_rule, only: %i[show update destroy]

      private

      def collection_scope = @resource.permission_set_rules
      def current_record = @rule
      def serializer_type = :permission_set_rule

      def build_record
        record = collection_scope.build(record_params)
        record.permission_set = @permission_set
        record
      end

      def set_rule
        @rule = find_nested_record(@resource.permission_set_rules)
      end

      def record_params
        pf_require_hash(:permission_set_rule).permit(
          :name, :field_name, :field_value, :operator,
          :join_type, :field_accessor_path, :include_nulls,
          :is_active, :is_editable, :failure_message
        )
      end
    end
  end
end
