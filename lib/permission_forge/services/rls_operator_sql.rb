# frozen_string_literal: true

module PermissionForge
  module Services
    # Operator -> SQL strategy registry for RLS policy generation, plus the
    # value-quoting helpers the strategies call back into. Extracted from
    # {RlsPolicyGenerator} for SRP/OCP — adding an operator translation is a
    # new registry entry, not a generator change.
    #
    # Each strategy receives (col, value, generator) and returns a SQL boolean
    # expression that selects the rows the app layer's strategy selects
    # (Operators::Registry). The value is the rule's, typed for the column by
    # the same Operators::ValueTyping — a literal, a list of them, or
    # {SessionUser} where `current_user` stands for the session variable. LIKE
    # is ILIKE on the column itself, as Arel writes it for PostgreSQL, with the
    # app layer's escaping. Where the app layer's query raises, the policy
    # shows no row: it is never the wider of the two.
    #
    # @api private
    module RlsOperatorSql
      # `current_user` in a policy: the SQL the session user's id is read with.
      SessionUser = Struct.new(:sql)
      # A value the policy computes when it runs (a relative date): its SQL.
      Dynamic = Struct.new(:sql)

      # PostgreSQL's relative date and time words, as the expression each
      # stands for when a statement runs. Quoted into a policy, PostgreSQL
      # resolves the word once, when it parses CREATE POLICY: the policy kept
      # the sync's date while the app layer, which sends the word with every
      # query, reads it anew. So the policy computes it per statement instead.
      RELATIVE_VALUES = {
        'now' => 'now()', 'today' => 'CURRENT_DATE', 'tomorrow' => '(CURRENT_DATE + 1)', 'yesterday' => '(CURRENT_DATE - 1)'
      }.freeze
      # A relative word anywhere in the text (`today 10:00`, `tomorrow UTC`):
      # no exact per-statement form is built for those — the rule is FALSE in
      # the policy (narrower than the app layer).
      RELATIVE_WORD = /\b(?:#{RELATIVE_VALUES.keys.join('|')})\b/i
      # The column types PostgreSQL reads those words for.
      TEMPORAL_TYPES = %i[date time datetime timestamp timestamptz].freeze

      UNUSABLE = Operators::ValueTyping::UNUSABLE

      OPERATOR_SQL = {
        Operators::Constants::EQUAL => ->(col, value, g) { "#{col} = #{g.value_sql(value)}" },
        Operators::Constants::NOT_EQUAL => ->(col, value, g) { "#{col} <> #{g.value_sql(value)}" },
        Operators::Constants::LESS_THAN => ->(col, value, g) { "#{col} < #{g.value_sql(value)}" },
        Operators::Constants::GREATER_THAN => ->(col, value, g) { "#{col} > #{g.value_sql(value)}" },
        Operators::Constants::LESS_THAN_OR_EQUAL => ->(col, value, g) { "#{col} <= #{g.value_sql(value)}" },
        Operators::Constants::GREATER_THAN_OR_EQUAL => ->(col, value, g) { "#{col} >= #{g.value_sql(value)}" },
        Operators::Constants::IN => ->(col, values, g) { "#{col} IN (#{g.list_sql(values)})" },
        Operators::Constants::NOT_IN => ->(col, values, g) { "#{col} NOT IN (#{g.list_sql(values)})" },
        Operators::Constants::CONTAINS => ->(col, value, g) { g.like_sql(col, value, prefix: '%', suffix: '%') },
        Operators::Constants::NOT_CONTAINS => lambda { |col, value, g|
          "NOT #{g.like_sql(col, value, prefix: '%', suffix: '%')}"
        },
        Operators::Constants::STARTS_WITH => ->(col, value, g) { g.like_sql(col, value, prefix: '', suffix: '%') },
        Operators::Constants::ENDS_WITH => ->(col, value, g) { g.like_sql(col, value, prefix: '%', suffix: '') },
        Operators::Constants::BETWEEN => ->(col, bounds, g) { "#{col} BETWEEN #{g.list_sql(bounds, ' AND ')}" },
        Operators::Constants::IS_NULL => ->(col, _value, _g) { "#{col} IS NULL" },
        Operators::Constants::IS_NOT_NULL => ->(col, _value, _g) { "#{col} IS NOT NULL" }
      }.freeze

      # The operators whose app-layer strategy adds the NULL rows under
      # include_nulls. The others ignore the flag, and so does the policy.
      NULL_INCLUDING = [
        Operators::Constants::EQUAL, Operators::Constants::NOT_EQUAL,
        Operators::Constants::IN, Operators::Constants::NOT_IN
      ].freeze

      # How the session user's id is read for a comparison, by the caster the
      # column's type has in the app layer: the id itself where the column is
      # a number (or a uuid) the id is one of, or of a type nothing is known
      # about, its text on a string column. A column of any other type (a
      # boolean, a date, an address, a json or array column, a native enum)
      # cannot equal an id — the rule is UNUSABLE there, as it is in the app
      # layer.
      # The database a policy is written for.
      POLICY_ADAPTER = 'PostgreSQL'

      SESSION_USER_SQL = {
        Operators::ValueCasters::UNTYPED => :uid_sql,
        Operators::ValueCasters::NUMBER => :numeric_uid_sql,
        Operators::ValueCasters::Number::SINGLE_PRECISION => :numeric_uid_sql,
        Operators::ValueCasters::PostgresqlTypes::UUID => :uuid_uid_sql,
        Operators::ValueCasters::TEXT => :uid_text_sql
      }.freeze

      # A rule's value as the app layer compares it with the column.
      #
      # @param target [Operators::RuleColumn] the column the rule names
      # @return [Object] a typed literal, an Array of them, a SessionUser, or UNUSABLE
      def typed_value(operator, value, target)
        return UNUSABLE if Operators::ValueTyping.no_column?(operator, target) || unmatchable?(operator, target)
        return session_user(operator, target) if Operators::ValueTyping.current_user?(operator, value)

        relative(Operators::ValueTyping.call(operator, value, target), temporal_sql_type(target.column))
      end

      def value_sql(value)
        case value
        when SessionUser, Dynamic then value.sql
        else connection.quote(value)
        end
      end

      def list_sql(values, separator = ', ')
        values.map { |value| value_sql(value) }.join(separator)
      end

      def like_sql(col, value, prefix:, suffix:)
        pattern = if value.is_a?(SessionUser)
                    [connection.quote(prefix), value.sql, connection.quote(suffix)].join(' || ')
                  else
                    connection.quote("#{prefix}#{Operators::Registry.sanitize_like(value)}#{suffix}")
                  end
        "#{col} ILIKE #{pattern} ESCAPE #{connection.quote(Operators::Registry::LIKE_ESCAPE)}"
      end

      private

      # A typed value (or each of a list's) with PostgreSQL's relative words
      # (RELATIVE_VALUES) as the expression PostgreSQL computes per statement,
      # cast to the column's type; text with such a word that is not the
      # word alone is UNUSABLE (FALSE). Only on a date or time column: on
      # any other a word is text, or was refused by the read back.
      def relative(value, sql_type)
        return value unless sql_type
        return relative_one(value, sql_type) unless value.is_a?(Array)

        typed = value.map { |element| relative_one(element, sql_type) }
        typed.any? { |element| element.equal?(UNUSABLE) } ? UNUSABLE : typed
      end

      # The column's SQL type when it is a date or time column, else nil.
      def temporal_sql_type(column)
        column.sql_type if column && TEMPORAL_TYPES.include?(column.type)
      end

      def relative_one(value, sql_type)
        return value unless value.is_a?(String) && value.match?(RELATIVE_WORD)

        expression = RELATIVE_VALUES[value.strip.downcase]
        expression ? Dynamic.new("CAST(#{expression} AS #{sql_type})") : UNUSABLE
      end

      # A LIKE operator on a column PostgreSQL cannot match a pattern with
      # (ValueCasters.pattern? for PostgreSQL, the database every policy is
      # for — as the app layer decides on PostgreSQL). A column the model
      # does not have is UNUSABLE, as in the app layer.
      def unmatchable?(operator, target)
        return false unless target.column && Operators::ValueTyping::SHAPES[operator] == :pattern

        !Operators::ValueCasters.pattern?(target.caster, POLICY_ADAPTER)
      end

      # A comparison takes the id as the column's type lets it. A LIKE pattern
      # is built from the id's text whatever the column (and a null check
      # takes no value at all).
      def session_user(operator, target)
        single = Operators::ValueTyping::SHAPES[operator] == :single
        reader = single ? SESSION_USER_SQL[target.caster] : :uid_text_sql
        sql = send(reader) if reader
        sql ? SessionUser.new(sql) : UNUSABLE
      end

      def uid_text_sql
        "(#{uid_sql})::text"
      end

      # An id that is not a number (a uuid) is never the value of a number column.
      def numeric_uid_sql
        uid_sql if user_id_caster.nil? || user_id_caster.equal?(Operators::ValueCasters::NUMBER)
      end

      # A uuid column equals the id only where user ids are uuids: compared
      # with the text of any other id, PostgreSQL raises (or the app layer,
      # with an id that is no uuid, matches nothing). A user_id column of
      # text that holds uuids is narrower here than in the app layer: FALSE.
      def uuid_uid_sql
        uid_sql if user_id_caster.equal?(Operators::ValueCasters::PostgresqlTypes::UUID)
      end

      def user_id_caster
        column = PermissionForge::SchemaRead.column(PermissionForge::PermissionSetUser, 'user_id')
        column && Operators::ValueCasters.for(column)
      end
    end
  end
end
