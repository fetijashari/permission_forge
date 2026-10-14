# frozen_string_literal: true

require_relative 'value_casters/number'
require_relative 'value_casters/temporal'

module PermissionForge
  module Operators
    # What a rule value becomes for a column of each ActiveRecord type: a Ruby
    # value the adapter quotes as that type, or {UNUSABLE} when the text is not
    # one of that type. Each caster is a `#call(value)`; {.for} picks the one
    # for a column.
    #
    # The notations are the same on every database and deliberately narrower
    # than Ruby's own parsers, which take `4_2`, `0x5` and `NaN`.
    module ValueCasters
      # A value the column cannot hold. A rule with one matches nothing.
      UNUSABLE = Object.new.tap { |marker| marker.define_singleton_method(:inspect) { 'UNUSABLE' } }.freeze

      # What PostgreSQL's boolean input takes. The id `current_user` stands for
      # is not text, and so never a boolean.
      BOOLEANS = {
        true => true, 'true' => true, 't' => true, 'yes' => true, 'y' => true, 'on' => true, '1' => true,
        false => false, 'false' => false, 'f' => false, 'no' => false, 'n' => false, 'off' => false, '0' => false
      }.freeze

      NUMBER = Number::EXACT

      BOOLEAN = ->(value) { BOOLEANS.fetch(value.is_a?(String) ? value.strip.downcase : value, UNUSABLE) }

      # Compared as written; the id `current_user` stands for, as its text.
      TEXT = ->(value) { value.nil? ? UNUSABLE : value.to_s }

      # A column type without a caster (uuid, json, an array column, ...) or a
      # field name that names no known column: the value is left to the database.
      UNTYPED = ->(value) { value }

      BY_TYPE = {
        integer: NUMBER, float: NUMBER, decimal: NUMBER,
        boolean: BOOLEAN,
        string: TEXT, text: TEXT,
        date: Temporal::DATE, time: Temporal::TIME,
        datetime: Temporal::DATETIME, timestamp: Temporal::DATETIME, timestamptz: Temporal::DATETIME
      }.freeze

      # PostgreSQL is typed like the others, with two things left the way it
      # always did them, so that no rule that works there stops working:
      #
      # - It reads date and time text itself and raises on what it cannot
      #   read. Text the Temporal casters do not recognise is left to it
      #   (`due_on less_than '31 Jan 2026'`, `due_on equal 'today'`); on SQLite
      #   and MySQL, which compare or convert such text, it stays UNUSABLE.
      # - A `real` column is compared in single precision (Number::SINGLE_PRECISION).
      #   The SQL type is the key: its ActiveRecord type is `float` as well.
      POSTGRESQL = BY_TYPE.transform_values { |caster| caster.is_a?(Temporal) ? caster.as_written : caster }
                          .merge('real' => Number::SINGLE_PRECISION).freeze

      # Adapter name => the casters of that database, where they are not BY_TYPE.
      BY_ADAPTER = { 'PostgreSQL' => POSTGRESQL, 'PostGIS' => POSTGRESQL }.freeze

      # The casters that read the two bounds of `between` together, where the
      # others cast one bound at a time. With nothing known about the column
      # the pair is read as it was before values were typed: both integers,
      # both decimals, both dates, or text.
      BOUNDS = {
        UNTYPED => ->(bounds) { Registry.coerce_between_values(*bounds) },
        Number::SINGLE_PRECISION => Number::SINGLE_PRECISION_BOUNDS
      }.freeze

      # @param column [ActiveRecord::ConnectionAdapters::Column, nil]
      # @param adapter_name [String, nil] the adapter of the column's model
      # @return [#call] the caster for the column
      def self.for(column, adapter_name = nil)
        return UNTYPED if column.nil? || column.try(:array?)

        casters = BY_ADAPTER.fetch(adapter_name, BY_TYPE)
        casters.fetch(column.sql_type) { casters.fetch(column.type, UNTYPED) }
      end
    end
  end
end
