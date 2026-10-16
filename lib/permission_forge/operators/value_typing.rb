# frozen_string_literal: true

module PermissionForge
  module Operators
    # Gives a rule value the type of the column it is compared with, so no
    # database is left to convert one side of a comparison.
    #
    # Rule values are text, and databases disagree about text compared with a
    # number, a boolean or a date: PostgreSQL raises on text it cannot cast,
    # SQLite compares as text, and MySQL converts — there `5 = '5_id'` and
    # `0 = 'abc'` are true, and a boolean column equals `'true'` exactly when
    # it is false. So the value is typed here, the same way for every database
    # and for the RLS policy (Services::RlsOperatorSql):
    #
    # - a value the column can hold is bound as a value of its type
    #   ({ValueCasters}); an enum label, as the value the model stores for it;
    # - a value it cannot hold is {UNUSABLE}: the rule matches nothing.
    #
    # PostgreSQL, which raises instead of guessing, keeps two habits of its own
    # (ValueCasters::POSTGRESQL): it reads date and time text in notations of
    # its own, and compares a `real` column in single precision.
    #
    # Only the built-in operators are typed, each by the shape of its value
    # ({SHAPES}). A custom operator's value is returned as it came, and a
    # column nothing is known about leaves the value to the database. A rule
    # with no column to compare with ({.no_column?}) is UNUSABLE: one whose
    # field_name is not a name, whatever the operator, and one that names a
    # column its table does not have, under a built-in operator. So is a
    # value with a NUL byte, under any operator ({.unquotable?}): no SQL
    # literal carries one — the database reads the statement cut short, and
    # every holder's query failed instead of being denied.
    module ValueTyping
      UNUSABLE = ValueCasters::UNUSABLE
      CURRENT_USER = 'current_user'

      # The shape of each built-in operator's value. The null checks take none.
      SHAPES = {
        Constants::EQUAL => :single, Constants::NOT_EQUAL => :single,
        Constants::LESS_THAN => :single, Constants::GREATER_THAN => :single,
        Constants::LESS_THAN_OR_EQUAL => :single, Constants::GREATER_THAN_OR_EQUAL => :single,
        Constants::IN => :list, Constants::NOT_IN => :list, Constants::BETWEEN => :pair,
        Constants::CONTAINS => :pattern, Constants::NOT_CONTAINS => :pattern,
        Constants::STARTS_WITH => :pattern, Constants::ENDS_WITH => :pattern
      }.freeze
      # The shapes read from the rule's text as a whole, comma by comma.
      SEVERAL = %i[list pair].freeze

      module_function

      # @param operator [String] the rule's operator
      # @param value [Object] the rule's value — the user's id where
      #   `current_user` stood for it (see {.current_user?})
      # @param target [RuleColumn] the column it is compared with
      # @return [Object] what the operator's strategy binds: one value, an Array
      #   for `in` / `not_in` / `between`, or {UNUSABLE}
      def call(operator, value, target)
        return UNUSABLE if no_column?(operator, target) || unquotable?(value)

        shape = SHAPES[operator]
        shape ? send(shape, value, target) : value
      end

      # Whether the value cannot be written into a statement as a literal: a
      # String with a NUL byte (a row written past the model; ParamShapes
      # drops NUL bytes from request parameters).
      #
      # @param value [Object] the rule's value
      def unquotable?(value)
        value.is_a?(String) && value.include?("\0")
      end

      # Whether the rule has no column to compare with: its field_name is not a
      # name (RuleColumn#malformed?), or — under a built-in operator — it names
      # a column its table does not have (RuleColumn#missing?), which the
      # database would reject. A custom operator's strategy decides what it
      # does with the name, so a missing column is left to it.
      #
      # @param operator [String] the rule's operator
      # @param target [RuleColumn] the column the rule names
      def no_column?(operator, target)
        target.malformed? || (target.missing? && Constants::OPERATORS.include?(operator))
      end

      # `current_user` stands for the user's id wherever one value is compared.
      # In a list it is an element like any other.
      def current_user?(operator, value)
        value == CURRENT_USER && SEVERAL.exclude?(SHAPES[operator])
      end

      # The caster for the column's type; an enum label is first replaced by
      # the value the model stores for it.
      #
      # @return [#call]
      def caster(target)
        typed = target.caster
        labels = target.enum
        return typed unless labels

        ->(value) { typed.call(labels.fetch(value.is_a?(String) ? value.strip : value, value)) }
      end

      def single(value, target)
        caster(target).call(value)
      end

      # A LIKE pattern is built from the text of the value, whatever the column.
      def pattern(value, _target)
        ValueCasters::TEXT.call(value)
      end

      # Every element has to be a value of the column; a list of none is no list.
      def list(value, target)
        elements = split(value)
        elements.empty? ? UNUSABLE : all_typed(elements, caster(target))
      end

      # Exactly two bounds, each a value of the column — or read together, by
      # the casters that do so (ValueCasters::BOUNDS).
      def pair(value, target)
        bounds = split(value)
        return UNUSABLE unless bounds.size == 2

        typed = caster(target)
        together = ValueCasters::BOUNDS[typed]
        together ? together.call(bounds) : all_typed(bounds, typed)
      end

      def split(value)
        value.to_s.split(',').map(&:strip)
      end

      def all_typed(elements, caster)
        typed = elements.map { |element| caster.call(element) }
        typed.include?(UNUSABLE) ? UNUSABLE : typed
      end

      private_class_method :caster, :single, :pattern, :list, :pair, :split, :all_typed
    end
  end
end
