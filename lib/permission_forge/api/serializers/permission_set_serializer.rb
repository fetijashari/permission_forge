# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      # `allowed_ips` is the stored text (commas between the entries since
      # 0.15); `allowed_ip_list` the entries as the engine reads them
      # (ActivationConditions) — what a client should write back.
      class PermissionSetSerializer < BaseSerializer
        attributes :id, :uuid, :name, :description, :is_active, :is_editable, :is_muting,
                   :requires_session_flag, :allowed_ips, :allowed_ip_list, :allowed_hours_start, :allowed_hours_end,
                   *reference(:permission_set_group), :created_at, :updated_at
      end
    end
  end
end
