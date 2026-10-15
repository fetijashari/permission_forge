# frozen_string_literal: true

module PermissionForge
  module Operators
    # The model column a rule's field_name names, as far as it can be told:
    # what {ValueTyping} goes by to give the rule's value that column's type.
    #
    # A plain name is a column of the model the rule ends on — its own, or the
    # last one on its association path. A dotted name (`customers.supplier_id`,
    # `public.customers.supplier_id`) says which table: the rule's own or one
    # along the path; a schema or database before it is not looked at. The
    # column is looked up the way the database resolves the name: among the
    # table's columns (a model's `ignored_columns` are still columns), and
    # without regard to case where the database has none ({EXACT_NAMES}) — a
    # name the database resolves has to be typed, or its value is compared as
    # text after all. A lookup that is more generous than the database costs
    # nothing: the database then rejects the name itself.
    #
    # When the table is none of the rule's, nothing is known ({UNKNOWN}) and
    # the value is left as it is: the name may be a table the query joins
    # itself (an association's alias, a default scope's join) — the database
    # resolves it or rejects it. A table of the rule's that has no such column
    # is {#missing?}: the database would reject the query, so a built-in
    # operator matches nothing for it (ValueTyping.no_column?). A field_name
    # that is not a name ({.name?}) is {#malformed?}: such a rule matches
    # nothing.
    class RuleColumn
      # Adapters whose database compares a quoted name as it is written. On
      # every other one — MySQL, SQLite — `Flag` is the column `flag`.
      EXACT_NAMES = %w[PostgreSQL PostGIS].freeze

      # @return [ActiveRecord::ConnectionAdapters::Column, nil]
      attr_reader :column
      # @return [Hash, nil] label => stored value, when the model declares the column an enum
      attr_reader :enum
      # @return [Class, nil] the model whose table the name was looked up in; nil when no table was
      attr_reader :model

      class << self
        # A field name is one name, or several joined by dots. An empty one
        # among them — a leading, trailing or doubled dot, or nothing at all —
        # makes it no name: quoted segment by segment it would be another
        # name than the one that was written.
        def name?(field_name)
          segments = field_name.to_s.split('.', -1)
          segments.any? && segments.none?(&:empty?)
        end

        # @param field_name [String] the rule's field_name
        # @param models [Array<Class>] the rule's model, then the model of each
        #   association on its path (see {.models_along})
        # @return [RuleColumn]
        def find(field_name, models)
          return MALFORMED unless name?(field_name)

          *qualifier, name = field_name.to_s.split('.')
          model = table_model(qualifier.last, models)
          model ? on(model, name) : UNKNOWN
        end

        # The column a rule row names, looked up the way PermissionRuleApplier
        # looks it up: in the model its Resource is named after and along its
        # association path (join rules only). nil when that cannot be told —
        # the Resource names no model, the model cannot be loaded, the path
        # cannot be followed, a table along it does not exist (asking a missing
        # table for its columns fails the statement, and with it a transaction)
        # or the database cannot be asked.
        #
        # @param rule [PermissionForge::PermissionSetRule]
        # @return [RuleColumn, nil]
        def for_rule(rule)
          model = rule_model(rule)
          return unless model

          models = models_along(model, rule.join_rule? ? rule.field_accessor_path.to_s.split('.') : [])
          find(rule.field_name, models) if models.any? && models.all?(&:table_exists?)
        rescue NameError, ArgumentError, ActiveRecord::ActiveRecordError
          nil
        end

        # The rule's own model, then the model of each association on its path;
        # a plain field_name is a column of the last one.
        #
        # @param model [Class] the rule's model
        # @param association_chain [Array<String>] the rule's field_accessor_path, split
        # @return [Array<Class>] empty when the path cannot be followed
        def models_along(model, association_chain)
          association_chain.reduce([model]) do |models, assoc|
            joined = models.last.reflect_on_association(assoc.to_sym)&.klass
            break [] unless joined

            models << joined
          end
        end

        private

        # The model the rule's Resource is named after, when it is one.
        def rule_model(rule)
          model = rule.resource&.name.to_s.safe_constantize
          model if model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class?
        end

        # The model a table name stands for; without one, the model the rule ends on.
        def table_model(table, models)
          return models.last unless table

          models.find { |model| same_name?(model.table_name.to_s.split('.').last, table, exact_names?(model)) }
        end

        def on(model, name)
          connection = model.connection
          column = column_named(connection.schema_cache.columns_hash(model.table_name), name, exact_names?(model))
          new(column, column && model.defined_enums[column.name], connection.adapter_name, model)
        end

        def column_named(columns, name, exact)
          columns[name] || columns.each_value.find { |column| same_name?(column.name, name, exact) }
        end

        def same_name?(own, written, exact)
          own == written || (!exact && own.casecmp?(written))
        end

        def exact_names?(model)
          EXACT_NAMES.include?(model.connection.adapter_name)
        end
      end

      def initialize(column, enum, adapter_name, model = nil)
        @column = column
        @enum = enum
        @adapter_name = adapter_name
        @model = model
      end

      # Nothing is known about the column: the name's table is none of the rule's.
      UNKNOWN = new(nil, nil, nil).freeze
      # The rule's field_name is not a name.
      MALFORMED = new(nil, nil, nil).freeze

      def malformed?
        equal?(MALFORMED)
      end

      # The name's table is one of the rule's ({#model}), and it has no such
      # column: the database would reject a query that compares it.
      def missing?
        !model.nil? && column.nil?
      end

      # The caster for the column's type, on the database it is in.
      #
      # @return [#call] see ValueCasters.for
      def caster
        ValueCasters.for(column, @adapter_name)
      end
    end
  end
end
