# frozen_string_literal: true

module PermissionForge
  module Operators
    module ValueCasters
      # Casts ISO 8601 text for a date, time or datetime column.
      #
      # The text is checked here (the notation, a real calendar day) and cast by
      # the ActiveRecord type of the column, so the adapter quotes the result the
      # way it stores that column: a date-time without an offset is read in the
      # database's time zone (`ActiveRecord.default_timezone`), one with an
      # offset is converted to it, and SQLite gets the text it compares with.
      # A date column takes the day of a date-time, a time column the time of
      # day. Anything else — another notation, `now`, `tomorrow`, the id that
      # `current_user` stands for — is UNUSABLE. (On PostgreSQL, which reads
      # date and time text itself, such text is asked of it:
      # PostgresqlTypes::ReadBack.)
      class Temporal
        DAY = /(?<year>\d{4})-(?<month>\d\d?)-(?<day>\d\d?)/
        CLOCK = /(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d+)?)?/
        OFFSET = /Z|[+-]\d\d(?::?\d\d)?/
        DAY_AND_CLOCK = /\A#{DAY}(?:[T ]#{CLOCK}(?: ?#{OFFSET})?)?\z/
        CLOCK_ONLY = /\A(?:\d{4}-\d\d-\d\d[T ])?#{CLOCK}\z/

        # @param format [Regexp] what the text has to look like
        # @param type [ActiveModel::Type::Value] casts the text and serializes the result
        def initialize(format, type)
          @format = format
          @type = type
        end

        def call(value)
          recognised(value) || UNUSABLE
        end

        DATE = new(DAY_AND_CLOCK, ActiveRecord::Type::Date.new)
        DATETIME = new(DAY_AND_CLOCK, ActiveRecord::Type::DateTime.new)
        TIME = new(CLOCK_ONLY, ActiveRecord::Type::Time.new)

        private

        def recognised(value)
          return unless value.is_a?(String)

          text = value.strip
          parts = @format.match(text)
          @type.serialize(@type.cast(text)) if parts && real_day?(parts)
        end

        # A time of day names no day; a date has to be one of the calendar.
        def real_day?(parts)
          year, month, day = parts.named_captures.values_at('year', 'month', 'day')
          year.nil? || Date.valid_date?(year.to_i, month.to_i, day.to_i)
        end
      end
    end
  end
end
