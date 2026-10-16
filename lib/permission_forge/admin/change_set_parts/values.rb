# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Stateless value rules shared by the ChangeSet collaborators.
      module Values
        # A flag of the change set's params (`pf[...]`), read as every
        # admin and API flag is (ParamShapes.boolean: the forms post "0" and
        # "1"); nil is false.
        #
        # @raise [ParamShapes::InvalidFlag] for anything else: ActiveModel's
        #   cast read "nope" as true (the admin answers with a flash)
        def self.truthy?(value)
          return false if value.nil?

          read = ParamShapes.boolean(value)
          read.nil? ? raise(ParamShapes::InvalidFlag, 'pf') : read
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
