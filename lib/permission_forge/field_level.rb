# frozen_string_literal: true

module PermissionForge
  # Maps the single "access level" of a field row to ResourceField flags and
  # back. Granting sets offer Hidden / Masked / Read-only / Editable; muting
  # sets offer Unchanged / Force mask / Hide, where the same flags mean
  # "remove" (see PermissionHashBuilder#mute_single_field). The admin's
  # controls, the ChangeSet, the effective-access views and the one row
  # builder (ResourceFieldGenerator::RowBuilder) all read the tables here.
  # Before 0.15.0 this lived at PermissionForge::Admin::FieldLevel, which is
  # kept as an alias.
  #
  # @api private
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

    # The level of a column with no setting: Unchanged in a Muting
    # Permission Set (it mutes nothing: one state, one name), none in a
    # granting one (unconfigured_field_strategy decides, and the row says so).
    def unconfigured_level(muting:)
      muting ? 'leave' : nil
    end

    # Whether a level is a row: every level of the set's kind, except
    # Unchanged in a Muting Permission Set — it mutes nothing, which is what
    # no row means. The one definition every path that creates rows reads
    # (the row builder, the admin's presets and bulk add, the generator).
    #
    # @return [Boolean]
    def row?(level, muting:)
      valid?(level, muting: muting) && !(muting && level.to_s == 'leave')
    end

    # The level a row gets on its Resource: on a granting set Editable needs
    # the Resource's Edit (the admin's level control disables it, turning
    # the Resource's Edit off cascades Editable rows to Read-only, the
    # effective-access views cap it), so without it Editable is Read-only —
    # the row says what the field allows. A muting set's levels take access
    # away and are never capped. The one definition every path that writes a
    # level reads: the row builder (after the privacy default, so an
    # Editable personal-data field becomes Read-only, never Masked) and the
    # Fields tab's level edits.
    #
    # @param level [String]
    # @param resource_edit [Boolean] the Resource grants Edit
    # @param muting [Boolean]
    # @return [String]
    def capped(level, resource_edit:, muting:)
      level = level.to_s
      level == 'edit' && !muting && !resource_edit ? 'read' : level
    end

    def flags_for(level, muting:)
      (muting ? MUTING : GRANTING).fetch(level.to_s) { raise ArgumentError, "Unknown field level: #{level.inspect}" }
    end

    def valid?(level, muting:)
      (muting ? MUTING : GRANTING).key?(level.to_s)
    end

    # Derives the level from a field's flags. Flag combinations the UI never
    # writes (e.g. edit + mask) collapse to the closest level.
    # What a muting row takes away, for provenance (the WHY panel): its
    # level, except a row that mutes edit but not read (API / console
    # only), which takes editing away and leaves the field readable:
    # 'no_edit', a level no form offers.
    def muting_provenance(field)
      level = level_of(field, muting: true)
      level == 'hide' && !field.read_access ? 'no_edit' : level
    end

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
