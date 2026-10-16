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
    # When the table is none of the rule's but exists, nothing is known
    # ({UNKNOWN}) and the value is left as it is: the query may join it
    # itself (a default scope's join, a host's `joins`) — the database
    # resolves the name or rejects it. When no such table exists either, the
    # name is {#unresolvable?} ({UNRESOLVABLE}) and the rule matches nothing
    # — the database would reject the query (`no such column: nosuch.name`),
    # and every holder would get an error instead of a denial — unless the
    # rule follows an association path: then the name may be the alias
    # ActiveRecord gives a table joined twice (`parents_customers` on a
    # self-join), which is no data source, so it is left to the database as
    # UNKNOWN. A table of the rule's that has no such column is {#missing?}:
    # the database would reject the query, so a built-in operator matches
    # nothing for it (ValueTyping.no_column?). A field_name that is not a
    # name ({.name?}) is {#malformed?}: such a rule matches nothing.
    class RuleColumn
      # Adapters whose database compares a quoted name as it is written. On
      # every other one — MySQL, SQLite — `Flag` is the column `flag`.
      EXACT_NAMES = %w[PostgreSQL PostGIS].freeze

      # What makes a rule's column or path "cannot tell" for a caller that
      # only describes it (for_rule, RuleProblem.of_path — the admin, the
      # audit, the model's checks): anything raised while the models are
      # loaded or asked, a model file's SyntaxError or LoadError included.
      # The applier's own walk does not rescue them (RulePath).
      UNTELLABLE = [StandardError, ScriptError].freeze
      # A character no name has (see .name?).
      CONTROL_CHARACTER = /[[:cntrl:]]/

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
        # name than the one that was written. So does a control character (a
        # newline, a NUL byte) in one: no column is called that, and quoted
        # into a statement it reaches the database as written.
        def name?(field_name)
          segments = field_name.to_s.split('.', -1)
          segments.any? && segments.none? { |segment| segment.empty? || segment.match?(CONTROL_CHARACTER) }
        end

        # @param field_name [String] the rule's field_name
        # @param models [Array<Class>] the rule's model, then the model of each
        #   association on its path (see {.models_along})
        # @return [RuleColumn]
        def find(field_name, models)
          return MALFORMED unless name?(field_name)
          return UNKNOWN if models.empty?

          *qualifier, name = field_name.to_s.split('.')
          table = qualifier.last
          model = table_model(table, models)
          return on(model, name) if model

          models.size > 1 || data_source?(models.last, table) ? UNKNOWN : UNRESOLVABLE
        end

        # Whether the connection has a data source (a table or view) named
        # `table`: asked only for a qualifier that is none of the rule's
        # tables. A "no" is asked of the database again once
        # (PermissionForge::SchemaRead.table?): the schema cache may predate
        # a table a migration just created.
        #
        # @param model [Class] a model on the connection
        # @param table [String] the name as written
        def data_source?(model, table)
          PermissionForge::SchemaRead.table?(model, table)
        end

        # The columns a rule may compare on a model: every column of its
        # table as the database knows them (a model's `ignored_columns`
        # among them, as in .find) — the names the admin's rule builder
        # offers and the model's validation accepts, one list.
        #
        # The list is compared with the database first
        # (PermissionForge::SchemaRead, `verify: true`): a column a migration
        # added since the schema was read is offered.
        #
        # @param model [Class] a model with a table
        # @return [Array<String>]
        def names_for(model)
          PermissionForge::SchemaRead.columns(model, verify: true).keys
        end

        # The column a rule row names, looked up the way PermissionRuleApplier
        # looks it up: in the model its Resource is named after and along its
        # association path (join rules only). nil when that cannot be told —
        # the Resource names no model, the model cannot be loaded (its file
        # raises anything as it loads: UNTELLABLE), the path cannot be
        # followed, a table along it does not exist (asking a missing table
        # for its columns fails the statement, and with it a transaction) or
        # the database cannot be asked.
        #
        # @param rule [PermissionForge::PermissionSetRule]
        # @return [RuleColumn, nil]
        def for_rule(rule)
          model = rule_model(rule)
          return unless model

          models = models_along(model, rule.join_rule? ? path_segments(rule.field_accessor_path) : [])
          find(rule.field_name, models) if models.any? && models.all? { |model| PermissionForge::SchemaRead.table?(model, model.table_name) }
        rescue *UNTELLABLE
          nil
        end

        # The rule's own model, then the model of each association on its path;
        # a plain field_name is a column of the last one. The path is
        # followed by {RulePath}, the way ActiveRecord joins it.
        #
        # @param model [Class] the rule's model
        # @param association_chain [Array<String>] the rule's field_accessor_path, split
        # @return [Array<Class>] empty when the path cannot be followed (RulePath#broken?)
        def models_along(model, association_chain)
          RulePath.follow(model, association_chain).models
        end

        # A rule's association path (its field_accessor_path), split into
        # the association names the applier joins; a blank one is no path.
        #
        # @param path [String, nil]
        # @return [Array<String>]
        def path_segments(path)
          path.blank? ? [] : path.to_s.split('.')
        end

        # The model the rule's Resource is named after, when it is one with a
        # table (PermissionForge::ModelLookup, the one definition).
        #
        # @param rule [PermissionForge::PermissionSetRule]
        # @return [Class, nil]
        def rule_model(rule)
          PermissionForge::ModelLookup.model_for(rule.resource&.name)
        end

        private

        # The model a table name stands for; without one, the model the rule ends on.
        def table_model(table, models)
          return models.last unless table

          models.find { |model| same_name?(model.table_name.to_s.split('.').last, table, exact_names?(model)) }
        end

        # The table's column of that name; a name the schema cache does not
        # have is looked up again once after the schema is read again
        # (PermissionForge::SchemaRead): a column a migration just added.
        def on(model, name)
          exact = exact_names?(model)
          column = PermissionForge::SchemaRead.column(model, name) { |columns| column_named(columns, name, exact) }
          new(column, column && model.defined_enums[column.name], model.connection.adapter_name, model)
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

      # Nothing is known about the column: the name's table is none of the
      # rule's — it exists (the query may join it), or the rule follows a
      # path and the name may be an alias the join gives.
      UNKNOWN = new(nil, nil, nil).freeze
      # The rule's field_name is not a name.
      MALFORMED = new(nil, nil, nil).freeze
      # The name's table is none of the rule's and no table of the database
      # (a rule that joins nothing): the database would reject the query.
      UNRESOLVABLE = new(nil, nil, nil).freeze

      def malformed?
        equal?(MALFORMED)
      end

      # The name is qualified with a table that is not there (see UNRESOLVABLE):
      # such a rule matches nothing.
      def unresolvable?
        equal?(UNRESOLVABLE)
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
