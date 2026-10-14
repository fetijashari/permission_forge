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
      # `current_user` stands for — is UNUSABLE, unless the caster is the one
      # for a database that reads such text itself ({#as_written}).
      class Temporal
        DAY = /(?<year>\d{4})-(?<month>\d\d?)-(?<day>\d\d?)/
        CLOCK = /(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d(?:\.\d+)?)?/
        OFFSET = /Z|[+-]\d\d(?::?\d\d)?/
        DAY_AND_CLOCK = /\A#{DAY}(?:[T ]#{CLOCK}(?: ?#{OFFSET})?)?\z/
        CLOCK_ONLY = /\A(?:\d{4}-\d\d-\d\d[T ])?#{CLOCK}\z/

        # @param format [Regexp] what the text has to look like
        # @param type [ActiveModel::Type::Value] casts the text and serializes the result
        # @param as_written [Boolean] hand text of another notation over as it is
        def initialize(format, type, as_written: false)
          @format = format
          @type = type
          @as_written = as_written
        end

        def call(value)
          return UNUSABLE unless value.is_a?(String)

          recognised(value.strip) || (@as_written ? value : UNUSABLE)
        end

        # The same caster for a database that reads date and time text itself
        # and raises on what it cannot read (PostgreSQL). Text this caster does
        # not recognise is handed over as it is written, as it was before
        # values were typed: `today`, a date in a local notation. What is not
        # text stays UNUSABLE.
        #
        # @return [Temporal]
        def as_written
          self.class.new(@format, @type, as_written: true)
        end

        DATE = new(DAY_AND_CLOCK, ActiveRecord::Type::Date.new)
        DATETIME = new(DAY_AND_CLOCK, ActiveRecord::Type::DateTime.new)
        TIME = new(CLOCK_ONLY, ActiveRecord::Type::Time.new)

        private

        def recognised(text)
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
