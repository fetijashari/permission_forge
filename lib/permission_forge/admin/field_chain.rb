# frozen_string_literal: true

module PermissionForge
  module Admin
    # The field entry tables a resource's fields are composed from, its own
    # first, then those of the single-table-inheritance bases the person has
    # an entry for — composed as ResourceChain.compose_field composes them
    # for the attribute guard: one entry decides alone; among several, one
    # that does not grant read hides every configured field, else the
    # strictest field entry decides (the first in chain order at its level).
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
        def rank_of(name) = PermissionForge::FieldLevel.rank(PermissionForge::FieldLevel.effective_level(fields[name]))
        def provenance(name) = FieldProvenance.new(fields[name], decided_by: decided_by)

        # A field hidden because this entry does not grant read (ResourceChain::HIDDEN_ENTRY).
        def hidden_attributes = FieldProvenance.hidden_by(sources.flags[:read_access].blocked_by, decided_by: decided_by)
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
        return hiding.hidden_attributes.merge(virtual: virtual) if hiding

        deciding(configured, name).provenance(name).attributes(virtual: virtual, editable: editable)
      end

      private

      # Among several entries, the first that does not grant read.
      def hiding
        return @hiding if defined?(@hiding)

        @hiding = (@tables.find { |table| !table.readable? } if @tables.size > 1)
      end

      def deciding(configured, name)
        configured.each_with_index.min_by { |table, index| [table.rank_of(name), index] }.first
      end
    end
  end
end
