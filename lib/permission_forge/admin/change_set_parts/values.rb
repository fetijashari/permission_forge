# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Stateless value rules shared by the ChangeSet collaborators.
      module Values
        def self.truthy?(value)
          ActiveModel::Type::Boolean.new.cast(value) == true
        end

        # Edit on a resource without Edit is downgraded to Read
        # (FieldLevel.capped, the one definition).
        def self.effective_level(level, resource, muting:)
          FieldLevel.capped(level, resource_edit: resource.edit_access, muting: muting)
        end
      end
    end
  end
end
