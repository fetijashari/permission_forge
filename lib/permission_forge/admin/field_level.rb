# frozen_string_literal: true

module PermissionForge
  module Admin
    # Maps the admin UI's single "access level" choice to ResourceField flags
    # and back. Granting sets offer Hidden / Masked / Read-only / Editable;
    # muting sets offer Unchanged / Force mask / Hide, where the same flags mean
    # "remove" (see PermissionHashBuilder#mute_single_field).
    module FieldLevel
      GRANTING = {
        'hidden' => { read_access: false, edit_access: false, mask_access: false },
        'masked' => { read_access: true, edit_access: false, mask_access: true },
        'read' => { read_access: true, edit_access: false, mask_access: false },
        'edit' => { read_access: true, edit_access: true, mask_access: false }
      }.freeze

      MUTING = {
        'leave' => { read_access: false, edit_access: false, mask_access: false },
        'mask' => { read_access: false, edit_access: false, mask_access: true },
        'hide' => { read_access: true, edit_access: true, mask_access: false }
      }.freeze

      # Ordered from most closed to most open (granting) — used to rank levels.
      GRANTING_ORDER = %w[hidden masked read edit].freeze

      module_function

      def levels_for(muting:)
        muting ? MUTING.keys : GRANTING.keys
      end

      def flags_for(level, muting:)
        (muting ? MUTING : GRANTING).fetch(level.to_s) { raise ArgumentError, "Unknown field level: #{level.inspect}" }
      end

      def valid?(level, muting:)
        (muting ? MUTING : GRANTING).key?(level.to_s)
      end

      # Derives the level from a field's flags. Flag combinations the UI never
      # writes (e.g. edit + mask) collapse to the closest level.
      def level_of(field, muting:)
        read = field.read_access
        edit = field.edit_access
        mask = field.mask_access
        return muting_level(read, edit, mask) if muting

        return 'hidden' unless read
        return 'masked' if mask

        edit ? 'edit' : 'read'
      end

      def muting_level(read, edit, mask)
        return 'hide' if read || edit

        mask ? 'mask' : 'leave'
      end

      # Level an engine field-permission entry resolves to
      # ({ read_access:, edit_access:, mask_access: } from the permissions hash).
      def effective_level(entry)
        return 'hidden' if entry.nil? || !entry[:read_access]
        return 'masked' if entry[:mask_access]

        entry[:edit_access] ? 'edit' : 'read'
      end

      def rank(level)
        GRANTING_ORDER.index(level.to_s) || -1
      end
    end
  end
end
