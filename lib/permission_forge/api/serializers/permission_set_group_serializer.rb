# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class PermissionSetGroupSerializer < BaseSerializer
        attributes :id, :uuid, :name, :description, :is_active, :is_editable,
                   :created_at, :updated_at
      end
    end
  end
end
