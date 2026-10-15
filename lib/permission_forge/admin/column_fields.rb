# frozen_string_literal: true

module PermissionForge
  module Admin
    # Creates ResourceFields for model columns and virtual fields at one level,
    # applying privacy defaults: under gdpr_defaults sensitive names added
    # Read-only start Masked, and the muting 'hide_sensitive' level hides only
    # sensitive names. Editable is full access (the "Full access" preset, "Add
    # all new with full access"): nothing is masked, every row keeps the
    # recommended strategy, and the privacy audit still flags the names.
    # Rails' timestamps are at most Read-only on a granting set
    # (PermissionForge::TimestampFields).
    #
    # @api private
    class ColumnFields
      # Granting levels that privacy defaults turn into Masked for a sensitive name.
      MASKED_BY_PRIVACY_DEFAULTS = %w[read].freeze

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
        attrs = attrs.merge(timestamps.overrides(column, read: attrs[:read_access]))
        @resource.resource_fields.create!(attrs.merge(name: column, label: column.humanize, is_active: true, is_editable: true,
                                                      mask_strategy: match&.strategy || 'full'))
      end

      def timestamps
        @timestamps ||= PermissionForge::TimestampFields.new(@resource.name.to_s.safe_constantize, muting: @muting)
      end

      def muting_level(level, match)
        return 'hide' if level == 'hide_sensitive' && match
        return nil if %w[hide_sensitive leave].include?(level) || level.blank?

        FieldLevel.valid?(level, muting: true) ? level : nil
      end

      def granting_level(level, match)
        return nil unless FieldLevel.valid?(level, muting: false)
        return 'masked' if match && MASKED_BY_PRIVACY_DEFAULTS.include?(level) && @configuration.gdpr_defaults

        level
      end
    end
  end
end
