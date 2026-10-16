# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class ResourceFieldSerializer < BaseSerializer
        attributes :id, :uuid, *reference(:resource), :name, :label, :description,
                   :is_active, :is_editable,
                   :read_access, :edit_access, :mask_access, :mask_strategy,
                   :created_at, :updated_at
      end
    end
  end
end
