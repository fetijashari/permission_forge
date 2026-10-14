# frozen_string_literal: true

module PermissionForge
  module Operators
    # Operator and join-type constants used by PermissionSetRule and Registry.
    # Extracted to keep PermissionSetRule's constant count manageable.
    # Include this module to access constants directly (e.g., EQUAL, JOINS).
    #
    # @api public
    module Constants
      # Join types
      LEFT_JOINS = 'left_joins'
      LEFT_OUTER_JOINS = 'left_outer_joins'
      JOINS = 'joins'

      JOIN_TYPES = [LEFT_JOINS, LEFT_OUTER_JOINS, JOINS].freeze

      # Operators
      EQUAL = 'equal'
      NOT_EQUAL = 'not_equal'
      LESS_THAN = 'less_than'
      GREATER_THAN = 'greater_than'
      LESS_THAN_OR_EQUAL = 'less_than_or_equal'
      GREATER_THAN_OR_EQUAL = 'greater_than_or_equal'
      IN = 'in'
      NOT_IN = 'not_in'
      CONTAINS = 'contains'
      NOT_CONTAINS = 'not_contains'
      STARTS_WITH = 'starts_with'
      ENDS_WITH = 'ends_with'
      BETWEEN = 'between'
      IS_NULL = 'is_null'
      IS_NOT_NULL = 'is_not_null'

      OPERATORS = [
        EQUAL, NOT_EQUAL, LESS_THAN, GREATER_THAN, LESS_THAN_OR_EQUAL, GREATER_THAN_OR_EQUAL,
        IN, NOT_IN, CONTAINS, NOT_CONTAINS, STARTS_WITH, ENDS_WITH, BETWEEN, IS_NULL, IS_NOT_NULL
      ].freeze
    end
  end
end
