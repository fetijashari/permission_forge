# frozen_string_literal: true

module PermissionForge
  module Admin
    # Assignment end-date presets. Calendar-day maths (date + n days), never
    # seconds, so DST changes don't shift labels. An assignment ending on a
    # date stays valid through the end of that day.
    module ExpiryPresets
      DAYS = { '1d' => 1, '1w' => 7, '30d' => 30 }.freeze
      KEYS = %w[1d 1w 30d eom custom never].freeze
      CHANGE_KEYS = %w[1w 30d eom never].freeze
      # Home's "Extend 30 days": 30 days past the current end date (or today).
      EXTEND_KEY = 'extend30'
      EXTEND_DAYS = 30

      class InvalidDate < StandardError; end

      module_function

      # @return [Date, nil] nil for "never"/"custom" without a date
      def date_for(key, today: Time.zone.today, custom: nil)
        case key.to_s
        when *DAYS.keys then today + DAYS.fetch(key.to_s)
        when 'eom' then today.end_of_month
        when 'custom' then parse_custom(custom, today)
        end
      end

      # The expires_at timestamp for a preset (end of the chosen day), or nil.
      def expires_at_for(key, today: Time.zone.today, custom: nil)
        date_for(key, today: today, custom: custom)&.in_time_zone&.end_of_day
      end

      # The end date a change of an assignment's end date gives: a CHANGE_KEYS
      # preset, or EXTEND_KEY (EXTEND_DAYS past `from`, or past today when
      # `from` is earlier or nil). :invalid for any other key.
      #
      # @param from [Time, nil] the end date the assignment has
      # @return [Time, nil, :invalid]
      def change_to(key, from:, today: Time.zone.today)
        key = key.to_s
        return ([from&.to_date, today].compact.max + EXTEND_DAYS).in_time_zone.end_of_day if key == EXTEND_KEY
        return :invalid unless CHANGE_KEYS.include?(key)

        expires_at_for(key, today: today)
      end

      def parse_custom(value, today)
        raise InvalidDate, :missing if value.blank?

        date = Date.iso8601(value.to_s)
        raise InvalidDate, :not_future unless date > today

        date
      rescue Date::Error
        raise InvalidDate, :missing
      end

      # Days until the assignment ends (0 = today, negative = ended), nil when
      # it never ends.
      def days_left(expires_at, today: Time.zone.today)
        return nil if expires_at.nil?

        (expires_at.to_date - today).to_i
      end
    end
  end
end
