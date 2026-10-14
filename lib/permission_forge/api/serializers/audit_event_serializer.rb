# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      # An audit event as the API shows it: every column but the tenant column
      # (internal), `data` as an object, times in ISO 8601 (UTC, microseconds).
      class AuditEventSerializer < BaseSerializer
        TIME_ATTRIBUTES = %i[occurred_at created_at].freeze

        attributes :id, :uuid, :occurred_at, :event, :category,
                   :actor_type, :actor_id, :actor_label, :source,
                   :record_type, :record_id, :record_uuid, :record_label,
                   :permission_set_id, :permission_set_uuid, :subject_user_id,
                   :data, :reason, :request_id, :ip, :correlation_id, :created_at

        TIME_ATTRIBUTES.each do |name|
          define_method(name) { record.public_send(name)&.utc&.iso8601(6) }
        end

        def data
          record.data.presence || {}
        end
      end
    end
  end
end
