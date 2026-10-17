# frozen_string_literal: true

module PermissionForge
  module Api
    module Serializers
      class PermissionSetUserSerializer < BaseSerializer
        attributes :id, :uuid, *reference(:permission_set), :user_id, :expires_at, :created_at, :updated_at
      end
    end
  end
end
