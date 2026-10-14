# frozen_string_literal: true

module PermissionForge
  module Admin
    # Files the admin hands over: the audit log (Exports::Events) and who
    # holds what (Exports::Holdings), written by Exports::Document.
    module Exports
      module_function

      # The metadata block every export starts with.
      #
      # @param kind [String] what was exported
      # @param exported_by [Audit::Actor]
      # @param filters [Hash]
      # @param row_count [Integer]
      # @param time_zone [String] the zone date-only filters were read in
      # @return [Hash{String => Object}]
      def meta(kind, exported_by:, filters:, row_count:, now: Time.current, time_zone: AuditLogDays.zone_name) # rubocop:disable Metrics/ParameterLists
        {
          'export' => kind,
          'exported_at' => now.utc.iso8601,
          'time_zone' => time_zone,
          'exported_by' => exported_by.label || exported_by.type,
          'exported_by_type' => exported_by.type,
          'exported_by_id' => exported_by.id,
          'filters' => filters.to_h.transform_keys(&:to_s),
          'row_count' => row_count
        }
      end

      # A file name: permission-forge-<kind>-<UTC timestamp>.<format>
      def filename(kind, format, now: Time.current)
        "permission-forge-#{kind.to_s.tr('_', '-')}-#{now.utc.strftime('%Y%m%dT%H%M%SZ')}.#{format}"
      end
    end
  end
end
