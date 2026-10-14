# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class PermissionSetSerializer < BaseSerializer
        attributes :id, :uuid, :name, :description, :is_active, :is_editable, :is_muting,
                   :requires_session_flag, :allowed_ips, :allowed_hours_start, :allowed_hours_end,
                   :permission_set_group_id, :created_at, :updated_at
      end
    end
  end
end
