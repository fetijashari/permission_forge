# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class ResourceActionSerializer < BaseSerializer
        attributes :id, :uuid, :resource_id, :name, :label, :description,
                   :is_permitted, :is_active,
                   :created_at, :updated_at
      end
    end
  end
end
