# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class PermissionSetRuleSerializer < BaseSerializer
        REDACTED_PLACEHOLDER = '[REDACTED]'

        attributes :id, :uuid, :permission_set_id, :resource_id,
                   :name, :failure_message, :join_type,
                   :field_name, :field_value, :field_accessor_path,
                   :operator, :include_nulls, :is_active, :is_editable,
                   :created_at, :updated_at

        private

        def field_value
          return REDACTED_PLACEHOLDER if PermissionForge.configuration.api_redact_rule_field_values

          record.field_value
        end
      end
    end
  end
end
