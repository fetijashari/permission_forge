# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Stateless value rules shared by the ChangeSet collaborators.
      module Values
        def self.truthy?(value)
          ActiveModel::Type::Boolean.new.cast(value) == true
        end

        # Edit on a resource without Edit is downgraded to Read (muting sets
        # have inverted semantics, so Edit is always available there).
        def self.effective_level(level, resource, muting:)
          level == 'edit' && !(muting || resource.edit_access) ? 'read' : level
        end
      end
    end
  end
end
