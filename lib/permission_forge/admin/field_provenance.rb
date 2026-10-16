# frozen_string_literal: true

module PermissionForge
  module Admin
    # The outcome of one effective field entry, and which Permission Sets it
    # credits (EX: the explanation comes from the entry that decides, never a
    # second walk).
    # The entry is Admin::EffectiveFields': the engine's own flags
    # (FieldPermissionMerger.merge_row, then the muting phase), plus
    # `sources` ([set, row level, row strategy] in merge order), `mutes`
    # ([set, level] in muting order) and `before` (the flags before muting).
    #
    # - grants: the sets that make the field readable, one each at its most
    #   open level, most open first and, at one level, in merge order — the
    #   first one is the entry's level and, masked, the row whose strategy
    #   the entry took. A Hidden row grants nothing and has no say in the
    #   mask; an implicit (virtual-field) entry credits no set.
    # - mutes: the muting sets that changed the entry (MUTE_EFFECTS), each at
    #   the strongest level it is credited with, the strongest first — the
    #   first one is the level the entry shows (hide → Hidden, mask → Masked,
    #   no_edit → Read-only). A mute that changed nothing (a field nobody
    #   shows, editing nobody gave) is not listed.
    #
    # @example
    #   FieldProvenance.new(entry, decided_by: nil).attributes(virtual: false, editable: true)
    #   # => { level: 'masked', capped: false, mask_strategy: 'email', grants: [FieldSource], mutes: [], ... }
    class FieldProvenance
      FieldSource = EffectiveAccess::FieldSource

      # What a muting set does to a field, strongest first (FieldSource#level).
      MUTING_ORDER = %w[hide mask no_edit].freeze
      # Whether a muting level changed the entry: (flags before muting, entry
      # after) => true. Hide took a readable field away; mask leaves it
      # masked; no_edit took editing away and left it readable.
      MUTE_EFFECTS = {
        'hide' => ->(before, after) { before[:read_access] == true && !after[:read_access] },
        'mask' => ->(_before, after) { PermissionForge::FieldLevel.effective_level(after) == 'masked' },
        'no_edit' => ->(before, after) { before[:edit_access] == true && after[:read_access] == true && !after[:edit_access] }
      }.freeze

      # The attributes of a field hidden because an entry does not grant
      # read (ResourceChain::HIDDEN_ENTRY): no set grants it; the muting sets
      # that took that entry's read away hide it.
      #
      # @param muting_sets [Array<PermissionForge::PermissionSet>]
      # @param decided_by [String, nil] the entry's Resource, for a base's
      # @return [Hash] EffectiveAccess::FieldOutcome attributes but name and virtual
      def self.hidden_by(muting_sets, decided_by:)
        mutes = muting_sets.map { |set| FieldSource.new(permission_set: set, level: 'hide') }
        { level: 'hidden', capped: false, unconfigured: false, implicit: false, unreadable: true, decided_by: decided_by,
          mask_strategy: ResourceChain::HIDDEN_ENTRY[:mask_strategy], granted_by: [], grants: [], blocked_by: muting_sets,
          mutes: mutes, blocked_level: mutes.first&.level }
      end

      # @param entry [Hash] an Admin::EffectiveFields entry
      # @param decided_by [String, nil] the base Resource whose entry it is
      #   (single-table inheritance), nil for the resource's own
      def initialize(entry, decided_by: nil)
        @entry = entry
        @decided_by = decided_by
      end

      # The entry's outcome and the sets it credits, as EffectiveAccess::FieldOutcome takes them.
      #
      # @param virtual [Boolean] the model declares the field (not a column)
      # @param editable [Boolean] the resource grants Edit: an editable field
      #   is capped to Read-only without it
      # @return [Hash] every FieldOutcome attribute but name and unconfigured
      def attributes(virtual:, editable:)
        granting = grants
        muting = mutes
        { virtual: virtual || implicit?, implicit: implicit?, mask_strategy: @entry[:mask_strategy],
          variant_of: @entry[:variant_of], decided_by: @decided_by, unreadable: false, **level(editable),
          granted_by: granting.map(&:permission_set), grants: granting, blocked_by: muting.map(&:permission_set),
          mutes: muting, blocked_level: muting.first&.level }
      end

      # An implicit (virtual-field) entry: no set configured the field.
      def implicit? = @entry[:extra].present?

      # @return [Array<EffectiveAccess::FieldSource>]
      def grants
        return [] if implicit?

        rows = @entry[:sources].each_with_index.select { |(_, level, _), _| FieldLevel.rank(level) >= 1 }
        rows.sort_by { |(_, level, _), index| [-FieldLevel.rank(level), index] }.map(&:first).uniq(&:first)
            .map { |set, level, strategy| FieldSource.new(permission_set: set, level: level, mask_strategy: strategy) }
      end

      # @return [Array<EffectiveAccess::FieldSource>]
      def mutes
        sources = credited_mutes.group_by(&:first).map { |set, rows| strongest(set, rows.map(&:last)) }
        sources.each_with_index.sort_by { |source, index| [MUTING_ORDER.index(source.level), index] }.map(&:first)
      end

      private

      # [set, level] for each muting row or resource that changed the entry.
      def credited_mutes
        (@entry[:mutes] || []).select { |_, level| changed?(level) }
      end

      def strongest(permission_set, levels)
        FieldSource.new(permission_set: permission_set, level: MUTING_ORDER.find { |level| levels.include?(level) })
      end

      # The entry's level (FieldLevel.effective_level); Edit is capped to
      # Read-only when the resource does not grant Edit.
      def level(editable)
        level = FieldLevel.effective_level(@entry)
        capped = level == 'edit' && !editable
        { level: capped ? 'read' : level, capped: capped }
      end

      def changed?(level)
        MUTE_EFFECTS.fetch(level).call(@entry[:before] || {}, @entry)
      end
    end
  end
end
