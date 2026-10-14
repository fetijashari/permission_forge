# frozen_string_literal: true

module PermissionForge
  module Admin
    # Creates ResourceFields for model columns and virtual fields at one level,
    # applying privacy defaults: sensitive names start Masked when gdpr_defaults
    # is on, and the muting 'hide_sensitive' level hides only sensitive names.
    class ColumnFields
      def initialize(resource, muting:, sensitive: SensitiveColumns.new, configuration: PermissionForge.configuration)
        @resource = resource
        @muting = muting
        @sensitive = sensitive
        @configuration = configuration
      end

      # @return [Integer] number of fields created (columns whose level resolves to nil are skipped)
      def create(columns, level)
        columns.filter_map { |column| create_field(column, level) }.size
      end

      private

      def create_field(column, level)
        match = @sensitive.match(column)
        column_level = @muting ? muting_level(level, match) : granting_level(level, match)
        return unless column_level

        attrs = FieldLevel.flags_for(column_level, muting: @muting)
        @resource.resource_fields.create!(attrs.merge(name: column, label: column.humanize, is_active: true, is_editable: true,
                                                      mask_strategy: match&.strategy || 'full'))
      end

      def muting_level(level, match)
        return 'hide' if level == 'hide_sensitive' && match
        return nil if %w[hide_sensitive leave].include?(level) || level.blank?

        FieldLevel.valid?(level, muting: true) ? level : nil
      end

      def granting_level(level, match)
        return nil unless FieldLevel.valid?(level, muting: false)
        return 'masked' if match && %w[read edit].include?(level) && @configuration.gdpr_defaults

        level
      end
    end
  end
end
