# frozen_string_literal: true

require 'ipaddr'
require 'concurrent/map'

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

        # The other notations PostgreSQL's uuid input takes, each read as the
        # 32 digits it holds: in braces, after `urn:uuid:`, without hyphens.
        UUID_NOTATIONS = [/\A\{(?<digits>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\}\z/, /\Aurn:uuid:(?<digits>\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/i,
                          /\A\{?(?<digits>\h{32})\}?\z/].freeze

        # A UUID in lower case, in RFC 4122 notation; anything else — text
        # that is no UUID, the Integer id `current_user` stands for — is UNUSABLE.
        UUID = lambda do |value|
          text = value.is_a?(String) ? value.strip : nil
          next UNUSABLE unless text
          next text.downcase if text.match?(UUID_FORMAT)

          digits = UUID_NOTATIONS.lazy.filter_map { |notation| notation.match(text)&.[](:digits) }.first&.delete('-')&.downcase
          digits ? [digits[0, 8], digits[8, 4], digits[12, 4], digits[16, 4], digits[20, 12]].join('-') : UNUSABLE
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

        # Text PostgreSQL reads itself: a column type no caster here knows
        # (hstore, money, interval, macaddr, xml, bit, ...) and date and time
        # text in a notation Temporal does not recognise (`today`, `31 Jan
        # 2026`). PostgreSQL raises on text it cannot read as the column's
        # type — for every holder, on every query — so the text is asked of
        # PostgreSQL once (a CAST in a savepoint) and the answer kept for the
        # process: what it reads is handed over as written, anything else is
        # UNUSABLE and the rule matches nothing. The caster wrapped, when
        # there is one, is tried first (a recognised date costs no query).
        class ReadBack
          # Answers kept per process before the memo starts over.
          LIMIT = 4096

          # Builds the caster for one column (ValueCasters.for calls `of`).
          Factory = Struct.new(:inner) do
            # @param column [ActiveRecord::ConnectionAdapters::Column]
            # @param model [Class, nil]
            # @return [ReadBack]
            def of(column, model) = ReadBack.new(inner, column.sql_type, model)
          end

          @answers = Concurrent::Map.new

          class << self
            # @param inner [#call, nil] the caster tried first
            # @return [Factory]
            def wrapping(inner) = Factory.new(inner)

            # Whether PostgreSQL reads `text` as a value of `sql_type`; asked
            # once per process and type.
            #
            # @param model [Class] a model on the connection
            # @param sql_type [String] the column's SQL type, from the schema
            # @param text [String]
            # @return [Boolean]
            def reads?(model, sql_type, text)
              key = [sql_type, text]
              known = @answers[key]
              return known unless known.nil?

              @answers.clear if @answers.size >= LIMIT
              @answers[key] = cast?(model, sql_type, text)
            end

            # @param value [Object] a rule value
            # @param numbers [Boolean] whether a number is asked as its text
            # @return [String, nil] the text PostgreSQL is asked to read
            def text_of(value, numbers:)
              return value if value.is_a?(String)

              value.to_s if numbers && value.is_a?(Numeric)
            end

            # Forgets the answers (tests).
            #
            # @return [void]
            def reset!
              @answers.clear
            end

            private

            # A failed statement aborts a PostgreSQL transaction: the CAST runs
            # in a savepoint of its own.
            def cast?(model, sql_type, text)
              model.connection_pool.with_connection do |connection|
                connection.transaction(requires_new: true) do
                  connection.select_value("SELECT CAST(#{connection.quote(text)} AS #{sql_type})")
                end
              end
              true
            rescue ActiveRecord::StatementInvalid
              false
            end
          end

          # @param inner [#call, nil]
          # @param sql_type [String]
          # @param model [Class, nil] without one PostgreSQL cannot be asked: UNUSABLE
          def initialize(inner, sql_type, model)
            @inner = inner
            @sql_type = sql_type
            @model = model
          end

          def call(value)
            typed = @inner ? @inner.call(value) : UNUSABLE
            typed.equal?(UNUSABLE) ? read_back(value) : typed
          end

          private

          # Unless a caster is wrapped (what it refuses as no text stays
          # refused), a number — the id `current_user` stands for — is asked as its text.
          def read_back(value)
            text = ReadBack.text_of(value, numbers: @inner.nil?)
            text && @model && ReadBack.reads?(@model, @sql_type, text) ? value : UNUSABLE
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
