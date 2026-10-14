# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class ResourceSerializer < BaseSerializer
        attributes :id, :uuid, :permission_set_id, :name, :description,
                   :is_active, :is_editable,
                   :read_access, :create_access, :edit_access, :delete_access,
                   :view_all, :modify_all,
                   :created_at, :updated_at
      end
    end
  end
end
