# frozen_string_literal: true

module PermissionForge
  module Admin
    # Creates ResourceFields for model columns and virtual fields at one
    # level: the admin's presets ("Add resource"), "Add all new" and "Sync
    # fields". The rows themselves come from the one row builder
    # (Services::ResourceFieldGenerator::RowBuilder): privacy defaults,
    # timestamps, the recommended strategy, the label. This class only turns
    # a preset into a level per column — the muting 'hide_sensitive' preset
    # hides the sensitive names and leaves the others alone — and skips the
    # levels that are no row (Unchanged, a level the set's kind lacks).
    #
    # @api private
    class ColumnFields
      # The muting levels that are a row (Unchanged is none).
      MUTING_ROW_LEVELS = %w[mask hide].freeze
      # The muting preset that hides the sensitive names and leaves the others.
      HIDE_SENSITIVE = 'hide_sensitive'

      def initialize(resource, muting:, sensitive: SensitiveColumns.new, configuration: PermissionForge.configuration)
        @resource = resource
        @muting = muting
        @sensitive = sensitive
        @rows = Services::ResourceFieldGenerator.rows(resource, muting: muting, configuration: configuration, sensitive: sensitive)
      end

      # @return [Integer] number of fields created (columns whose level resolves to nil, and blank names, are skipped)
      def create(columns, level)
        columns.filter_map { |column| create_field(column, level) }.size
      end

      private

      def create_field(column, level)
        column_level = column_level(column, level)
        return unless column_level

        attrs = @rows.attrs(column, column_level)
        @resource.resource_fields.create!(attrs) if attrs
      end

      # @return [String, nil] the level the column's row gets, nil for no row
      def column_level(column, level)
        return level if @muting ? MUTING_ROW_LEVELS.include?(level) : FieldLevel.valid?(level, muting: false)

        'hide' if @muting && level == HIDE_SENSITIVE && @sensitive.sensitive?(column)
      end
    end
  end
end
