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

      # The column types PostgreSQL has ILIKE for. On a column of any other
      # type the app layer's LIKE query raises, so the rule compiles to FALSE.
      LIKE_TYPES = %i[string text citext].freeze

      # How the session user's id is read for a comparison, by the caster the
      # column's type has in the app layer: the id itself where the column is
      # a number or of a type nothing is known about, its text on a string
      # column. A column of any other type (a boolean, a date) cannot equal an
      # id — the rule is UNUSABLE there, as it is in the app layer.
      SESSION_USER_SQL = {
        Operators::ValueCasters::UNTYPED => :uid_sql,
        Operators::ValueCasters::NUMBER => :numeric_uid_sql,
        Operators::ValueCasters::Number::SINGLE_PRECISION => :numeric_uid_sql,
        Operators::ValueCasters::TEXT => :uid_text_sql
      }.freeze

      # A rule's value as the app layer compares it with the column.
      #
      # @param target [Operators::RuleColumn] the column the rule names
      # @return [Object] a typed literal, an Array of them, a SessionUser, or UNUSABLE
      def typed_value(operator, value, target)
        return UNUSABLE if Operators::ValueTyping.no_column?(operator, target) || unmatchable?(operator, target.column)
        return session_user(operator, target) if Operators::ValueTyping.current_user?(operator, value)

        Operators::ValueTyping.call(operator, value, target)
      end

      def value_sql(value)
        case value
        when SessionUser then value.sql
        else connection.quote(value)
        end
      end

      def list_sql(values, separator = ', ')
        values.map { |value| connection.quote(value) }.join(separator)
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

      # A LIKE operator on a column PostgreSQL cannot match a pattern with. (A
      # column the model does not have is UNUSABLE, as in the app layer.)
      def unmatchable?(operator, column)
        return false unless column && Operators::ValueTyping::SHAPES[operator] == :pattern

        column.try(:array?) || LIKE_TYPES.exclude?(column.type)
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
        column = PermissionForge::PermissionSetUser.columns_hash['user_id']
        uid_sql if column.nil? || Operators::ValueCasters.for(column).equal?(Operators::ValueCasters::NUMBER)
      end
    end
  end
end
