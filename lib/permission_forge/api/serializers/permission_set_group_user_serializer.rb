# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class PermissionSetGroupUserSerializer < BaseSerializer
        attributes :id, :uuid, *reference(:permission_set_group), :user_id, :created_at, :updated_at
      end
    end
  end
end
