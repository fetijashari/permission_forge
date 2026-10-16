# frozen_string_literal: true

require 'ipaddr'

module PermissionForge
  module Operators
    module ValueCasters
      # Casters for the column types only PostgreSQL has: `uuid`, `inet`,
      # `cidr` and native enum types (`CREATE TYPE ... AS ENUM`). PostgreSQL
      # raises on text it cannot read as such a type (`invalid input syntax
      # for type uuid: "banana"`), so a value that is not one is UNUSABLE —
      # the rule matches nothing — instead of failing every holder's query.
      # The notations taken are narrower than PostgreSQL's own input, so that
      # what is typed here is always read by it.
      #
      # None of these types has a LIKE operator in PostgreSQL ({.pattern?}).
      module PostgresqlTypes
        # The text of a UUID as RFC 4122 writes it: 32 hex digits in groups of
        # 8-4-4-4-12, in either case. The version and variant digits are not
        # looked at (the nil UUID and newer versions are UUIDs to PostgreSQL).
        UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

        # An IPv4 or IPv6 address, then optionally a prefix length — the
        # notation PostgreSQL's inet and cidr input share (no netmask, no zone).
        NETWORK_FORMAT = %r{\A[\h:.]+(?:/\d{1,3})?\z}

        # A UUID in lower case; anything else — another notation, the Integer
        # id `current_user` stands for — is UNUSABLE.
        UUID = lambda do |value|
          text = value.is_a?(String) ? value.strip : nil
          text&.match?(UUID_FORMAT) ? text.downcase : UNUSABLE
        end

        # An address IPAddr reads, with an optional prefix length, as written.
        INET = ->(value) { PostgresqlTypes.network(value) || UNUSABLE }

        # A network: no bits set right of the prefix length (PostgreSQL
        # raises on `10.0.0.5/24` for a cidr column).
        CIDR = lambda do |value|
          text = PostgresqlTypes.network(value)
          next UNUSABLE unless text

          address = text.split('/').first
          IPAddr.new(text).to_i == IPAddr.new(address).to_i ? text : UNUSABLE
        end

        # The casters a LIKE pattern means nothing to.
        PATTERNLESS = [UUID, INET, CIDR].freeze

        # @param value [Object] a rule value
        # @return [String, nil] the address as written, when IPAddr reads it
        def self.network(value)
          text = value.is_a?(String) ? value.strip : nil
          return unless text&.match?(NETWORK_FORMAT)

          IPAddr.new(text)
          text
        rescue IPAddr::Error
          nil
        end

        # A native enum type's caster: one of the type's labels, exactly as
        # the database has it (surrounding spaces aside), else UNUSABLE. The
        # labels are read from the database (PermissionForge::SchemaRead,
        # read again once before a label is called missing: one added by a
        # migration while the process runs). Without the model the labels
        # cannot be read, and no value is usable.
        class NativeEnum
          # @param column [ActiveRecord::ConnectionAdapters::Column] a column of a native enum type
          # @param model [Class, nil] the model whose table the column is in
          # @return [NativeEnum]
          def self.of(column, model)
            new(column.sql_type, model)
          end

          # @param type [String] the column's SQL type: the enum type's name
          # @param model [Class, nil]
          def initialize(type, model)
            @type = type
            @model = model
          end

          def call(value)
            return UNUSABLE unless @model && value.is_a?(String)

            [value, value.strip].uniq.find { |label| SchemaRead.enum_label?(@model, @type, label) } || UNUSABLE
          end
        end

        # @param caster [#call] a caster of ValueCasters
        # @return [Boolean] whether a LIKE pattern can be matched against a
        #   column of the caster's type
        def self.pattern?(caster)
          PATTERNLESS.none? { |patternless| patternless.equal?(caster) } && !caster.is_a?(NativeEnum)
        end
      end
    end
  end
end
