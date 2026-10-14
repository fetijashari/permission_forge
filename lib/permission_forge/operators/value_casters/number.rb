# frozen_string_literal: true

require 'bigdecimal'

module PermissionForge
  module Operators
    module ValueCasters
      # Casts the text of a number for an integer, decimal or float column.
      module Number
        # A plain decimal, or one in scientific notation (`1e3`): every
        # database reads both.
        FORMAT = /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d{1,3})?\z/
        BIGINT = (-(2**63)..((2**63) - 1))
        # Past the range of a double the databases part ways again: PostgreSQL
        # raises on a float column, MySQL and SQLite round a tiny number to zero.
        DOUBLE = (Float::MIN..Float::MAX)
        # What a single-precision float holds, a little short of both ends.
        SINGLE = (1.1754944e-38..3.4028234e38)

        # A whole number that fits 64 bits is an Integer, however it is written
        # (`50`, `50.0`, `5e1`): compared with an integer column it can use the
        # column's index, where a decimal makes PostgreSQL cast every row. Any
        # other number — a fraction, one past that range — is a BigDecimal,
        # which every adapter writes as an exact numeric literal: the database
        # compares numbers (`supplier_id < 5.5`, `supplier_id <
        # 99999999999999999999`) and never casts text to the column's type.
        EXACT = lambda do |value|
          text = value.to_s.strip
          next UNUSABLE unless text.match?(FORMAT)

          decimal = BigDecimal(text)
          next decimal.to_i if decimal.frac.zero? && BIGINT.cover?(decimal)

          decimal.zero? || DOUBLE.cover?(decimal.abs) ? decimal : UNUSABLE
        end

        # For a PostgreSQL `real` column. PostgreSQL compares it with a number
        # in double precision, where 0.1 is not the 0.1 the column stores; text
        # it reads as a `real`. So the rule's text is handed over as the text
        # of the number it was checked to be, and compared in single precision
        # — as it was before values were typed. Two things stay numbers: the
        # id `current_user` stands for, and a number no `real` can hold, which
        # equals none and on which PostgreSQL would raise as text. MySQL
        # compares a FLOAT in double precision whatever it gets, and SQLite
        # has doubles only: there the number goes as a number (EXACT).
        SINGLE_PRECISION = lambda do |value|
          number = EXACT.call(value)
          next number unless value.is_a?(String) && !number.equal?(UNUSABLE)
          next number unless number.zero? || SINGLE.cover?(number.abs)

          number.is_a?(Integer) ? number.to_s : number.to_s('F')
        end

        # The two bounds of `between` on a PostgreSQL `real` column, likewise
        # as they always were: two plain integers or two plain decimals went
        # to PostgreSQL as numbers (the reading still made where nothing is
        # known about a column), any other pair as text.
        SINGLE_PRECISION_BOUNDS = lambda do |bounds|
          numbers = bounds.map { |bound| EXACT.call(bound) }
          next UNUSABLE if numbers.include?(UNUSABLE)

          plain = Registry.coerce_between_values(*bounds).first.is_a?(Numeric)
          plain ? numbers : bounds.map { |bound| SINGLE_PRECISION.call(bound) }
        end
      end
    end
  end
end
