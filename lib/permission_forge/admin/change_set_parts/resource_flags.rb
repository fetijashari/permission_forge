# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Resource label/description and CRUD/scope flags (see ResourceEdit).
      class ResourceFlags < Base
        def call
          section('resources').flat_map do |id, attrs|
            resource = unlocked_resource(id)
            next [] unless resource && attrs.is_a?(Hash)

            ResourceEdit.new(resource, muting: muting?).changes(attrs)
          end
        end
      end
    end
  end
end
