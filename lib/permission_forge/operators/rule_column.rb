# frozen_string_literal: true

require 'active_support/core_ext/module/delegation'

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
    # When the table is none of the rule's, what the name is depends on the
    # names the rule's query gives its tables ({RuleSources}: the FROM and
    # JOINs, with the aliases ActiveRecord assigns — never a name that merely
    # appears in a join condition): a name the join gives that is no model
    # table (`parents_customers` on a self-join) is {UNKNOWN} and left to the
    # database — unless the column it names holds ciphertext
    # ({EncryptedAlias}: the alias is resolved to the table it stands for and
    # the models along the path on that table; one that cannot be resolved
    # counts as encrypted when any model along the path encrypts a column of
    # that name), when it is that model's column, {#encrypted?}; a real table
    # that is none of the rule's is {FOREIGN} (a filter
    # rule compares its model's own table: it matches nothing; a join rule's
    # query has to join that table itself); anything else is {#unresolvable?}
    # ({UNRESOLVABLE}) and the rule matches nothing — the database would
    # reject the query (`no such column: supplier_id.id`), and every holder
    # would get an error instead of a denial. A table of the rule's that has
    # no such column is {#missing?}: the database would reject the query, so
    # a built-in operator matches nothing for it (ValueTyping.no_column?). A
    # field_name that is not a name ({.name?}) is {#malformed?}: such a rule
    # matches nothing. A column of an attribute declared with `encrypts`
    # holds ciphertext ({#encrypted?}): no built-in operator that takes a
    # value can compare it (ValueTyping).
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
        # @param joined [Hash{String => String, nil}, Array<String>, nil] the
        #   names a join rule's query gives its tables, with the table each
        #   stands for ({RuleSources.tables}; a list of names: tables not
        #   known); nil for a filter rule, whose query joins nothing of its own
        # @return [RuleColumn]
        def find(field_name, models, joined: nil)
          return MALFORMED unless name?(field_name)
          return UNKNOWN if models.empty?

          *qualifier, name = field_name.to_s.split('.')
          table = qualifier.last
          model = table_model(table, models) || EncryptedAlias.new(models, joined).model(table, name)
          model ? on(model, name) : elsewhere(table, models.last, joined)
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
        # @param verify [Boolean] false when the caller compared the columns already
        # @return [Array<String>]
        def names_for(model, verify: true)
          PermissionForge::SchemaRead.columns(model, verify: verify).keys
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
        # `verify: true` (a rule being saved) compares the columns of every
        # model along the path with the database first (one metadata query
        # each, PermissionForge::SchemaRead): a name the process confirmed
        # missing before a migration added it is accepted at save. The
        # describing callers (the admin's pages, the audit) ask without it.
        #
        # @param rule [PermissionForge::PermissionSetRule]
        # @param verify [Boolean]
        # @return [RuleColumn, nil]
        def for_rule(rule, verify: false)
          model = rule_model(rule)
          return unless model

          chain = rule.join_rule? ? path_segments(rule.field_accessor_path) : []
          models = models_along(model, chain)
          find(rule.field_name, models, joined: rule_join_names(rule, model, chain)) if readable?(models, verify)
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

        # Whether `written` names `own` the way the database compares names
        # (exactly where it compares a quoted name as written: EXACT_NAMES).
        #
        # @param own [String] the name as the schema or the model has it
        # @param written [String] the name as the rule writes it
        # @param exact [Boolean] see #exact_names?
        def same_name?(own, written, exact)
          own == written || (!exact && own.casecmp?(written))
        end

        # Whether the model's database compares a quoted name as written.
        #
        # @param model [Class]
        def exact_names?(model)
          EXACT_NAMES.include?(adapter_name(model))
        end

        private

        # A qualifier that is none of the rule's models: a name the query
        # gives a table (an alias: `joined` is a Hash of name => table, or a
        # list of names), a real table, or nothing at all.
        def elsewhere(table, model, joined)
          return UNKNOWN if joined&.any? { |source, _table| same_name?(source, table, exact_names?(model)) }

          data_source?(model, table) ? FOREIGN : UNRESOLVABLE
        end

        # nil for a filter rule (no join of its own); a join rule's join
        # names, read only for a qualified field_name.
        def rule_join_names(rule, model, chain)
          return unless rule.join_rule?

          rule.field_name.to_s.include?('.') ? RuleSources.of_join(model, rule.join_type, chain) : {}
        end

        # Every table along the path is there (asking a missing one for its
        # columns fails the statement); compared with the database first when
        # `verify`.
        def readable?(models, verify)
          return false unless models.any? && models.all? { |model| PermissionForge::SchemaRead.table?(model, model.table_name) }

          models.each { |model| PermissionForge::SchemaRead.columns(model, verify: true) } if verify
          true
        end

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
          new(column, column && model.defined_enums[column.name], adapter_name(model), model)
        end

        def column_named(columns, name, exact)
          columns[name] || columns.each_value.find { |column| same_name?(column.name, name, exact) }
        end

        # Through the pool, never `model.connection` (it raises under
        # ActiveRecord.permanent_connection_checkout = :disallowed).
        def adapter_name(model)
          model.connection_pool.with_connection(&:adapter_name)
        end
      end

      def initialize(column, enum, adapter_name, model = nil)
        @column = column
        @enum = enum
        @adapter_name = adapter_name
        @model = model
      end

      # Nothing is known about the column: the name's table is none of the
      # rule's models but a name the rule's query gives a table (an alias a
      # join gives), or the path cannot be followed.
      UNKNOWN = new(nil, nil, nil).freeze
      # The name's table is a real table that is none of the rule's (not its
      # model's, not one along its path or its query's joins): a filter rule
      # matches nothing (RuleProblem :foreign_table); a join rule's query has
      # to join it itself, or it matches nothing too.
      FOREIGN = new(nil, nil, nil).freeze
      # The rule's field_name is not a name.
      MALFORMED = new(nil, nil, nil).freeze
      # The name's table is none of the rule's and no table of the database
      # (a rule that joins nothing): the database would reject the query.
      UNRESOLVABLE = new(nil, nil, nil).freeze

      def malformed?
        equal?(MALFORMED)
      end

      # The name is qualified with a real table that is none of the rule's (see FOREIGN).
      def foreign?
        equal?(FOREIGN)
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

      # Whether the column holds ciphertext: an attribute of {#model} — the
      # class the rule is applied to (the applier's model class), one along
      # its path, or the one an alias of its query joins (EncryptedAlias) —
      # declared with `encrypts` by it or a class of its hierarchy on its
      # table (PermissionForge::EncryptedAttributes). Asked with the column's
      # own name (a field name written in another case resolves to it).
      def encrypted?
        return false if model.nil? || column.nil?

        PermissionForge::EncryptedAttributes.encrypted?(model, column.name)
      end

      class << self
        # @!method encrypted?(model, name)
        #   Whether `name` is a column of `model` that holds ciphertext (an
        #   attribute declared with `encrypts`; PermissionForge::EncryptedAttributes,
        #   the one definition): a rule can only ask whether it is empty. What
        #   the admin's rule builder asks before it offers a column.
        #   @param model [Class, nil] the model whose table the column is in
        #   @param name [String, Symbol] the column's name, as the model has it
        #   @return [Boolean]
        delegate :encrypted?, to: PermissionForge::EncryptedAttributes
      end

      # The caster for the column's type, on the database it is in.
      #
      # @return [#call] see ValueCasters.for
      def caster
        ValueCasters.for(column, @adapter_name, model)
      end

      # Whether a LIKE pattern can be matched against the column, on the
      # database it is in (ValueCasters.pattern?).
      def pattern?
        ValueCasters.pattern?(caster, @adapter_name)
      end
    end
  end
end
