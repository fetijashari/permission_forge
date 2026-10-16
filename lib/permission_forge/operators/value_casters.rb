# frozen_string_literal: true

require_relative 'value_casters/number'
require_relative 'value_casters/temporal'
require_relative 'value_casters/postgresql_types'

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

      # A column type without a caster (hstore, money, xml, ...) or a field
      # name that names no known column: the value is left to the database.
      UNTYPED = ->(value) { value }

      # A json, jsonb or array column: no rule value is one of its values.
      # PostgreSQL raised on most texts compared with one, and the others
      # (an array or JSON literal) compare a whole document; MySQL and SQLite
      # compare text. A rule on such a column matches nothing under every
      # built-in operator that takes a value — the null checks take none and
      # work — and a custom operator gets the value as written.
      OPAQUE = ->(_value) { UNUSABLE }

      BY_TYPE = {
        integer: NUMBER, float: NUMBER, decimal: NUMBER,
        boolean: BOOLEAN,
        string: TEXT, text: TEXT,
        date: Temporal::DATE, time: Temporal::TIME,
        datetime: Temporal::DATETIME, timestamp: Temporal::DATETIME, timestamptz: Temporal::DATETIME,
        json: OPAQUE, jsonb: OPAQUE,
        # Types only PostgreSQL has (PostgresqlTypes); no other adapter reports them.
        uuid: PostgresqlTypes::UUID, inet: PostgresqlTypes::INET, cidr: PostgresqlTypes::CIDR,
        enum: PostgresqlTypes::NativeEnum
      }.freeze

      # PostgreSQL is typed like the others, with three differences:
      #
      # - It reads date and time text itself and raises on what it cannot
      #   read. Text the Temporal casters do not recognise is asked of it
      #   (PostgresqlTypes::ReadBack): what it reads is handed over
      #   (`due_on less_than '31 Jan 2026'`, `due_on equal 'today'`), anything
      #   else is UNUSABLE. On SQLite and MySQL, which compare or convert such
      #   text, it is UNUSABLE.
      # - A column type no caster knows (hstore, money, interval, ...) is
      #   asked of it the same way ({ADAPTER_RULES}); `citext` is text.
      # - A `real` column is compared in single precision (Number::SINGLE_PRECISION).
      #   The SQL type is the key: its ActiveRecord type is `float` as well.
      POSTGRESQL = BY_TYPE.transform_values { |caster| caster.is_a?(Temporal) ? PostgresqlTypes::ReadBack.wrapping(caster) : caster }
                          .merge('real' => Number::SINGLE_PRECISION, 'citext' => TEXT).freeze

      # Adapter name => the casters of that database, where they are not BY_TYPE.
      BY_ADAPTER = { 'PostgreSQL' => POSTGRESQL, 'PostGIS' => POSTGRESQL }.freeze

      # What a database's casters decide apart from the column types:
      # - `unknown_type`: the caster of a column type none of its casters
      #   knows. UNTYPED (the value is left to the database) where a value of
      #   another notation is compared or converted; read back where the
      #   database raises on one.
      # - `patterns`: the casters a LIKE pattern can be matched against, where
      #   not every type has LIKE. PostgreSQL has it for text alone (an
      #   integer, a date, a boolean raise there) — and a column nothing is
      #   known about (an alias a join gives) is left to it.
      ADAPTER_RULES = {}.compare_by_identity.merge!(
        POSTGRESQL => { unknown_type: PostgresqlTypes::ReadBack.wrapping(nil), patterns: [TEXT, UNTYPED].freeze }.freeze
      ).freeze

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
      # @param model [Class, nil] the model whose table the column is in (a
      #   native enum's labels are read through it)
      # @return [#call] the caster for the column
      def self.for(column, adapter_name = nil, model = nil)
        return UNTYPED if column.nil?
        return OPAQUE if column.try(:array?)

        casters = BY_ADAPTER.fetch(adapter_name, BY_TYPE)
        caster = casters.fetch(column.sql_type) { casters.fetch(column.type) { ADAPTER_RULES.dig(casters, :unknown_type) || UNTYPED } }
        caster.respond_to?(:of) ? caster.of(column, model) : caster
      end

      # Whether a LIKE pattern can be matched against a column of the
      # caster's type. Not a json or array column, nor one of the PostgreSQL
      # types without LIKE (uuid, inet, cidr, a native enum), nor — on
      # PostgreSQL — anything but text ({ADAPTER_RULES}): a rule with a LIKE
      # operator on one matches nothing.
      #
      # @param caster [#call] a caster {.for} returned
      # @param adapter_name [String, nil] the adapter of the column's model
      def self.pattern?(caster, adapter_name = nil)
        only = ADAPTER_RULES.dig(BY_ADAPTER[adapter_name], :patterns)
        return only.any? { |allowed| allowed.equal?(caster) } if only

        !caster.equal?(OPAQUE) && PostgresqlTypes.pattern?(caster)
      end
    end
  end
end
