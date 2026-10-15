# frozen_string_literal: true

module PermissionForge
  module Admin
    module ChangeSetParts
      # Base for the ChangeSet collaborators. Each part turns one params
      # section into a list of ChangeSet::Change and assigns (never saves) the
      # new values on the in-memory records; ChangeSet#apply! persists them.
      class Base
        def initialize(context)
          @context = context
        end

        private

        delegate :permission_set, :params, :sensitive, :muting?, :section, :resources, :resource_of, :refused,
                 to: :@context

        def change(**attrs)
          ChangeSet::Change.new(**attrs)
        end

        # Assigns the change on its record; nil when effectively unchanged.
        def assign_change(**attrs)
          change(**attrs).assign
        end

        def valid_level?(level)
          FieldLevel.valid?(level, muting: muting?)
        end

        def flags_for(level)
          FieldLevel.flags_for(level, muting: muting?)
        end

        # The resource for `id`, unless missing or locked.
        def unlocked_resource(id)
          resource = resources[id.to_s]
          resource unless resource.nil? || locked?(resource)
        end

        def bulk
          section('bulk')
        end

        # Records flagged is_editable: false are managed by the system/API and
        # are never changed from the admin UI (their disabled inputs still post).
        def locked?(record)
          record.respond_to?(:is_editable) && record.is_editable == false
        end

        def truthy?(value)
          Values.truthy?(value)
        end
      end
    end
  end
end
