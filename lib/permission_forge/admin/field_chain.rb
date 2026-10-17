# frozen_string_literal: true

module PermissionForge
  module Admin
    # The field entry tables a resource's fields are composed from, its own
    # first, then those of the single-table-inheritance bases the person has
    # an entry for — composed as ResourceChain.compose_field composes them
    # for the attribute guard: one entry decides alone; among several, one
    # that does not grant read hides every configured field, else the
    # strictest field entry decides (the first in chain order at its level;
    # at Hidden or Read-only, one no mute brought there first). A muting set
    # is credited with hiding the field, or taking its editing away, only
    # when the granting sets alone, composed the same way, would show it,
    # or let it be edited (review R4 P1-2).
    # Admin::EffectiveFields builds it; FieldProvenance words the entry that
    # decides.
    #
    # @example
    #   chain = FieldChain.new([FieldChain::Table.new(sources, entries, nil)])
    #   chain.attributes('email', virtual: false, editable: true) # => { level: 'masked', ... } or nil
    class FieldChain
      # One entry table (`fields`: name => Admin::EffectiveFields entry): the
      # resource's own (decided_by nil) or a base's (decided_by: the base
      # Resource's name).
      Table = Struct.new(:sources, :fields, :decided_by) do
        def readable? = sources.flags[:read_access].granted?
        # Whether a granting set grants read, muted later or not.
        def granted_readable? = sources.flags[:read_access].granted_by.any?
        def rank_of(name) = PermissionForge::FieldLevel.rank(PermissionForge::FieldLevel.effective_level(fields[name]))
        def provenance(name) = FieldProvenance.new(fields[name], decided_by: decided_by)
        # The field's flags as the granting sets alone left them.
        def granted(name) = fields[name][:before] || fields[name]
        # Whether a muting set brought the field to its level.
        def muted?(name) = provenance(name).mutes.any?

        # A field hidden because this entry does not grant read (ResourceChain::HIDDEN_ENTRY).
        def hidden_attributes = FieldProvenance.hidden_by(sources.flags[:read_access].muted_on, decided_by: decided_by)
      end

      # @param tables [Array<Table>] the resource's first, then its bases' nearest first
      def initialize(tables)
        @tables = tables
      end

      # Every field name an entry along the chain has.
      #
      # @return [Array<String>]
      def names = @tables.flat_map { |table| table.fields.keys }

      # The FieldOutcome attributes but its name, from the entry that decides;
      # nil when no entry configures the field.
      #
      # @return [Hash, nil]
      def attributes(name, virtual:, editable:)
        configured = @tables.select { |table| table.fields.key?(name) }
        return if configured.empty?
        return chain_mutes(hiding.hidden_attributes.merge(virtual: virtual), configured, name) if hiding

        chain_mutes(deciding(configured, name).provenance(name).attributes(virtual: virtual, editable: editable), configured, name)
      end

      # Mutes that hide the field, or take its editing away, which the
      # granting sets alone (composed along the chain) never showed, or never
      # let be edited, are not credited. One entry: FieldProvenance did it.
      CHAIN_MUTE_EFFECTS = {
        'hide' => ->(granted) { granted[:read_access] == true },
        'no_edit' => ->(granted) { granted[:edit_access] == true }
      }.freeze
      private_constant :CHAIN_MUTE_EFFECTS

      private

      def chain_mutes(attributes, configured, name)
        return attributes if @tables.size <= 1

        granted = granted_composition(configured, name)
        mutes = attributes[:mutes].select { |mute| CHAIN_MUTE_EFFECTS.fetch(mute.level, ->(_) { true }).call(granted) }
        attributes.merge(mutes: mutes, blocked_by: mutes.map(&:permission_set), blocked_level: mutes.first&.level)
      end

      # The field as the granting sets alone compose it (ResourceChain.compose_field).
      def granted_composition(configured, name)
        return ResourceChain::HIDDEN_ENTRY unless @tables.all?(&:granted_readable?)

        ResourceChain.strictest(configured.map { |table| table.granted(name) })
      end

      # Among several entries, the first that does not grant read.
      def hiding
        return @hiding if defined?(@hiding)

        @hiding = (@tables.find { |table| !table.readable? } if @tables.size > 1)
      end

      # The strictest entry; at one level the first in chain order, but at
      # Hidden or Read-only one no mute brought there first (the masked
      # strategy is the first masking entry's, as the engine takes it).
      def deciding(configured, name)
        configured.each_with_index.min_by do |table, index|
          rank = table.rank_of(name)
          [rank, rank == MASKED_RANK || !table.muted?(name) ? 0 : 1, index]
        end.first
      end

      MASKED_RANK = PermissionForge::FieldLevel.rank('masked')
      private_constant :MASKED_RANK
    end
  end
end
