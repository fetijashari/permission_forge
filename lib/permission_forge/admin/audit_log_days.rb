# frozen_string_literal: true

module PermissionForge
  module Admin
    # The audit log page shows dates in the admin's time zone (Time.zone), so
    # a date-only "from" / "to" means that day there: from its first to its
    # last microsecond, with the offset written out for Audit::EventQuery
    # (which reads a bare date as a UTC day — the JSON API keeps that).
    # Anything else (a timestamp, an impossible date, a list) is left for
    # EventQuery to accept or refuse.
    module AuditLogDays
      DATE = /\A(\d{4})-(\d{2})-(\d{2})\z/

      module_function

      # @param filters [Hash] the filters as given (string keys)
      # @param zone [ActiveSupport::TimeZone]
      # @return [Hash] the same, date-only from / to as local-day timestamps
      def localize(filters, zone: Time.zone)
        filters.merge(%w[from to].each_with_object({}) do |key, out|
          day = local_day(filters[key], zone)
          out[key] = (key == 'from' ? day.beginning_of_day : day.end_of_day).iso8601(6) if day
        end)
      end

      def local_day(value, zone)
        match = value.is_a?(String) && DATE.match(value)
        return nil unless match && zone

        year, month, day = match.captures.map(&:to_i)
        zone.local(year, month, day) if year.positive? && Date.valid_date?(year, month, day)
      end

      # The zone's name for the page and the export metadata ("Pacific/Auckland").
      def zone_name(zone = Time.zone)
        name = zone.tzinfo&.name || zone.name
        name == 'Etc/UTC' ? 'UTC' : name
      end
    end
  end
end
