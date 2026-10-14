# frozen_string_literal: true

module PermissionForge
  # @api private
  module Operators
    # Strategy Pattern registry mapping operator names to query-building callables.
    #
    # Each operator receives (query, sanitized_column, rule, value) and returns
    # an ActiveRecord::Relation. The value arrives typed for the column it is
    # compared with (see {ValueTyping}): one value for the comparisons and the
    # text of a LIKE pattern, an Array for `in` / `not_in` (the list) and
    # `between` (the two bounds). To add a new operator, register it in
    # {.strategies} and define the corresponding class method.
    #
    # @example Fetching and calling an operator
    #   strategy = PermissionForge::Operators::Registry.fetch('equal')
    #   strategy.call(query, '"customers"."status"', rule, 'active')
    #
    # @api public
    module Registry
      module_function

      # @param name [String] operator constant from PermissionSetRule (e.g., 'equal')
      # @return [#call] callable strategy
      # @raise [ArgumentError] if operator is unknown
      def fetch(name)
        strategies.fetch(name) { raise ArgumentError, "Unknown operator: #{name}" }
      end

      # @return [Hash<String, #call>] frozen operator lookup table
      def strategies
        @strategies ||= build_strategies.freeze
      end

      # Resets the memoized strategies hash. Useful in tests after defining custom operators.
      def reset!
        @strategies = nil
      end

      # Wraps a pre-quoted column reference in Arel.sql so that downstream
      # .where calls treat it as a trusted SQL literal. The column has already
      # been quoted with the connection's real identifier quoting
      # (quote_table_name / quote_column_name) in
      # PermissionForge::Services::PermissionRuleApplier before reaching the
      # Registry — values are still bound as parameters, never interpolated.
      #
      # @param col [String] already-quoted column (e.g. '"table"."column"')
      # @return [Arel::Nodes::SqlLiteral]
      def arel_col(col)
        Arel.sql(col)
      end

      # Wraps a bare Equality predicate in Grouping. Required for default_scope
      # compatibility: Model.new/create runs scope_for_create, whose
      # WhereClause#to_h(equality_only: true) dereferences `.relation` on
      # top-level Equality nodes — our left operand is a SqlLiteral (no
      # `.relation`), which would raise NoMethodError on every create for a
      # scoped user. `to_h` skips Grouping nodes, so wrapping makes the
      # predicate invisible to create-attribute inference while leaving the
      # read-path SQL semantically identical: (("t"."col" = ?)).
      #
      # @param predicate [Arel::Nodes::Equality]
      # @return [Arel::Nodes::Grouping]
      def grouped(predicate)
        Arel::Nodes::Grouping.new(predicate)
      end

      # --- Operator implementations ---

      def op_equal(query, col, rule, val)
        column = arel_col(col)
        return query.where(column.eq(val).or(column.eq(nil))) if rule[:include_nulls]

        query.where(grouped(column.eq(val)))
      end

      # The `not_equal` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_not_equal(query, col, rule, val)
        column = arel_col(col)
        base = query.where(column.not_eq(val))
        return base.or(query.where(column.eq(nil))) if rule[:include_nulls]

        base
      end

      # The `in` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_in(query, col, rule, val)
        column = arel_col(col)
        values = list_values(rule, val)
        return query.where(column.in(values).or(column.eq(nil))) if rule[:include_nulls]

        query.where(column.in(values))
      end

      # The `not_in` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_not_in(query, col, rule, val)
        column = arel_col(col)
        values = list_values(rule, val)
        return query.where(column.not_in(values).or(column.eq(nil))) if rule[:include_nulls]

        query.where(column.not_in(values))
      end

      # The `contains` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_contains(query, col, _rule, val)
        column = arel_col(col)
        query.where(column.matches("%#{sanitize_like(val)}%", LIKE_ESCAPE))
      end

      # The `not_contains` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_not_contains(query, col, _rule, val)
        column = arel_col(col)
        query.where(column.does_not_match("%#{sanitize_like(val)}%", LIKE_ESCAPE))
      end

      # The `starts_with` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_starts_with(query, col, _rule, val)
        column = arel_col(col)
        query.where(column.matches("#{sanitize_like(val)}%", LIKE_ESCAPE))
      end

      # The `ends_with` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_ends_with(query, col, _rule, val)
        column = arel_col(col)
        query.where(column.matches("%#{sanitize_like(val)}", LIKE_ESCAPE))
      end

      # The node is built here, not from a Ruby Range: the bounds are already
      # typed, and not every pair of them makes a Range (two booleans do not).
      def op_between(query, col, rule, val)
        bounds = range_values(rule, val).map { |bound| Arel::Nodes.build_quoted(bound) }
        query.where(Arel::Nodes::Between.new(arel_col(col), Arel::Nodes::And.new(bounds)))
      end

      # The `less_than` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_less_than(query, col, _rule, val)
        query.where(arel_col(col).lt(val))
      end

      # The `greater_than` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_greater_than(query, col, _rule, val)
        query.where(arel_col(col).gt(val))
      end

      # The `less_than_or_equal` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_less_than_or_equal(query, col, _rule, val)
        query.where(arel_col(col).lteq(val))
      end

      # The `greater_than_or_equal` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_greater_than_or_equal(query, col, _rule, val)
        query.where(arel_col(col).gteq(val))
      end

      # The `is_null` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_is_null(query, col, _rule, _val)
        query.where(grouped(arel_col(col).eq(nil)))
      end

      # The `is_not_null` operator strategy: `(query, col, rule, val)` returning a relation.
      # @return [ActiveRecord::Relation]
      # @api private
      def op_is_not_null(query, col, _rule, _val)
        query.where(arel_col(col).not_eq(nil))
      end

      # --- Helpers ---

      def parse_list_value(rule)
        rule[:field_value].to_s.split(',').map(&:strip)
      end

      # The list as PermissionRuleApplier typed it for the column. A strategy
      # called directly with anything else reads the rule's own text, as it
      # did before values were typed.
      def list_values(rule, val)
        val.is_a?(Array) ? val : parse_list_value(rule)
      end

      # The two bounds, likewise.
      def range_values(rule, val)
        return val if val.is_a?(Array)

        lower, upper = parse_list_value(rule)
        coerce_between_values(lower, upper)
      end

      # `%`, `_` and the escape character itself match literally. The pattern
      # only means that with an ESCAPE clause: SQLite has no default escape
      # character, and neither has MySQL under NO_BACKSLASH_ESCAPES. The
      # adapter quotes the clause, which is what keeps it one backslash there
      # (trilogy does; the mysql2 driver cannot quote any text in that mode).
      LIKE_ESCAPE = '\\'

      # Escapes `%`, `_` and the escape character so a value is matched literally by LIKE.
      # @return [String]
      # @api private
      def sanitize_like(value)
        value.to_s.gsub(/[%_\\]/) { |char| "#{LIKE_ESCAPE}#{char}" }
      end

      INTEGER_PATTERN = /\A-?\d+\z/
      FLOAT_PATTERN = /\A-?\d+\.\d+\z/
      DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

      COERCION_RULES = [
        [INTEGER_PATTERN, lambda(&:to_i)],
        [FLOAT_PATTERN,   lambda(&:to_f)],
        [DATE_PATTERN,    ->(v) { Date.parse(v) }]
      ].freeze

      # Types the two bounds of a `between` rule the same way (dates, times, numbers).
      # @return [Array]
      # @api private
      def coerce_between_values(lower, upper)
        COERCION_RULES.each do |pattern, coercer|
          next unless lower.match?(pattern) && upper.match?(pattern)

          return [coercer.call(lower), coercer.call(upper)]
        end
        [lower, upper]
      rescue Date::Error
        [lower, upper]
      end

      # Builds the operator-to-strategy mapping by merging categorized sub-groups.
      def build_strategies
        comparison_operators.merge(set_operators).merge(string_operators).merge(range_and_null_operators)
      end

      # @return [Hash{String => Method}] the equality and ordering operators
      # @api private
      def comparison_operators
        psr = PermissionForge::PermissionSetRule
        {
          psr::EQUAL => method(:op_equal),
          psr::NOT_EQUAL => method(:op_not_equal),
          psr::LESS_THAN => method(:op_less_than),
          psr::GREATER_THAN => method(:op_greater_than),
          psr::LESS_THAN_OR_EQUAL => method(:op_less_than_or_equal),
          psr::GREATER_THAN_OR_EQUAL => method(:op_greater_than_or_equal)
        }
      end

      # @return [Hash{String => Method}] `in` and `not_in`
      # @api private
      def set_operators
        psr = PermissionForge::PermissionSetRule
        { psr::IN => method(:op_in), psr::NOT_IN => method(:op_not_in) }
      end

      # @return [Hash{String => Method}] `contains`, `not_contains`, `starts_with` and `ends_with`
      # @api private
      def string_operators
        psr = PermissionForge::PermissionSetRule
        {
          psr::CONTAINS => method(:op_contains),
          psr::NOT_CONTAINS => method(:op_not_contains),
          psr::STARTS_WITH => method(:op_starts_with),
          psr::ENDS_WITH => method(:op_ends_with)
        }
      end

      # @return [Hash{String => Method}] `between`, `is_null` and `is_not_null`
      # @api private
      def range_and_null_operators
        psr = PermissionForge::PermissionSetRule
        {
          psr::BETWEEN => method(:op_between),
          psr::IS_NULL => method(:op_is_null),
          psr::IS_NOT_NULL => method(:op_is_not_null)
        }
      end
    end
  end
end
