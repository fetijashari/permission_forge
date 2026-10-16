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

      # A list for field_value under in / not_in / between is joined with
      # commas; the stored rule's operator decides on an update that sends
      # none (Api::InputShapes).
      def record_params
        pf_record_attributes(:permission_set_rule, PermissionForge::PermissionSetRule,
                             :name, :field_name, :field_value, :operator,
                             :join_type, :field_accessor_path, :include_nulls,
                             :is_active, :is_editable, :failure_message, record: current_record)
      end
    end
  end
end
