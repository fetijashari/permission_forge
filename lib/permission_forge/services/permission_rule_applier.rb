module PermissionForge
  module Services
    # Applies row-level permission rules to build a scoped ActiveRecord query.
    # Extracted from PermissionScopedFindable for SRP and testability.
    #
    # Column references are quoted with the connection's real identifier quoting
    # (quote_table_name / quote_column_name) rather than string interpolation, so
    # a malformed field_name can never reach SQL as a literal even if a rule was
    # created through a path that bypasses model validation.
    #
    # A stored rule never raises here. A value of a rule row the applier
    # cannot interpret — a join type or operator this version does not know,
    # a path that cannot be followed, a field name that is not a name or
    # names a column its table does not have or a table that is not there, a
    # value the column cannot hold — makes the rule match nothing: every
    # holder is denied every record of the resource, never handed an error
    # (a 500 for every holder, on every query under auto_query_scoping). The
    # same reading describes such a rule to the admin and the audit
    # (Operators::RuleProblem).
    #
    # @api private
    class PermissionRuleApplier
      # join_type => the relation method that makes the join. The model
      # validates join_type, but a rule row can be written past the model (the
      # tables are shared with other applications): the value is looked up
      # here, never sent to the relation, and anything else matches nothing.
      JOIN_METHODS = {
        PermissionForge::Operators::Constants::JOINS => :joins,
        PermissionForge::Operators::Constants::LEFT_JOINS => :left_joins,
        PermissionForge::Operators::Constants::LEFT_OUTER_JOINS => :left_outer_joins
      }.freeze

      def self.call(model_class:, rules:, args:, current_user: PermissionForge.current_user,
                    operator_registry: PermissionForge::Operators::Registry)
        new(model_class:, rules:, args:, current_user:, operator_registry:).call
      end

      # Builds the rule-constrained relation without evaluating a specific record
      # or computing failure messages. Used by the `permission_scoped` relation
      # API so callers can chain further `.where`, `.first`, `.find`, etc.
      #
      # @return [ActiveRecord::Relation]
      def self.scope(model_class:, rules:, current_user: PermissionForge.current_user,
                     operator_registry: PermissionForge::Operators::Registry)
        new(model_class:, rules:, args: nil, current_user:, operator_registry:).scoped_relation
      end

      # @return [ActiveRecord::Relation] all rules applied, no args/denial check
      def scoped_relation
        report_no_rules if @rules.empty?
        @rules.reduce(@model_class.where(nil)) { |q, rule| build_rule_query(q, rule) }
      end

      def initialize(model_class:, rules:, args:, current_user:, operator_registry:)
        @model_class = model_class
        @rules = rules
        @args = args
        @current_user = current_user
        @operator_registry = operator_registry
      end

      # The query, the denial's messages (`[Forbidden by Rule: <name>] with
      # message: <failure_message>`, one per denying rule) and the denying
      # rules (the rule hashes themselves, in the same order); both empty when
      # nothing denied.
      #
      # @return [Array(ActiveRecord::Relation, Array<String>, Array<Hash>)]
      def call
        report_no_rules if @rules.empty?
        query = @rules.reduce(@model_class.where(nil)) { |q, rule| build_rule_query(q, rule) }

        # Happy path is a single existence check: rule constraints are monotonic
        # (each only removes rows), so if the fully-constrained query still matches
        # the target, no individual rule denied it.
        return [query, [], []] if @rules.empty? || matches?(query)

        # Denial path only: attribute the denial to the rules that deny the
        # record (one query per rule, solely when access is denied).
        denying = denying_rules
        [query, denying.map { |rule| rule_failure_message(rule) }, denying]
      end

      private

      # Called with no rules (the gem's own callers check first; a host app
      # calling the applier directly may not): rule.bypassed, no_rules.
      def report_no_rules
        PermissionForge::Audit::Runtime.bypassed(:no_rules, model: @model_class, via: 'rule_applier', user: @current_user)
      end

      def rule_failure_message(rule)
        "[Forbidden by Rule: #{rule[:name]}] with message: #{rule[:failure_message]}"
      end

      # The rules that deny the record each on its own: the model's relation,
      # that one rule and the args — rules combine with AND, so a rule that
      # keeps the record on its own did not deny it, whatever the others do.
      # In rule order. Should no single rule deny (an interplay with a default
      # scope, say), the cumulative attribution — the first rule whose
      # addition removes the record, and every rule after it — so a denial
      # never names no rule.
      def denying_rules
        denying = @rules.reject { |rule| matches?(build_rule_query(@model_class.where(nil), rule)) }
        denying.empty? ? cumulatively_denying_rules : denying
      end

      def cumulatively_denying_rules
        denying = []
        @rules.reduce(@model_class.where(nil)) do |q, rule|
          next_query = build_rule_query(q, rule)
          denying << rule if denying.any? || !matches?(next_query)
          next_query
        end
        denying
      end

      def matches?(query)
        query.where(*@args).exists?
      end

      # A join type that is none of JOIN_METHODS (written past the model, or
      # by a newer version) matches nothing: it is never sent to the relation.
      def build_rule_query(query, rule)
        join_type = rule[:join_type].to_s
        return apply_filter(query, rule) if PermissionForge::PermissionSetRule.filter_join_type?(join_type)

        join_method = JOIN_METHODS[join_type]
        join_method ? apply_join(query, rule, join_method) : query.none
      end

      def apply_filter(query, rule)
        column = quoted_column(@model_class.table_name, rule[:field_name])
        build_query(query, column, rule, [@model_class])
      end

      # A path that cannot be followed (Operators::RulePath#broken?: no such
      # association, a polymorphic one, a class that cannot be loaded...)
      # matches nothing: ActiveRecord would raise for the join when the query
      # runs, and every holder would get an error instead of a denial.
      def apply_join(query, rule, join_method)
        association_chain = PermissionForge::Operators::RuleColumn.path_segments(rule[:field_accessor_path])
        models = joinable_models(association_chain)
        return query.none unless models

        query = joined(query, join_method, association_chain)
        field_name = rule[:field_name]
        return query.none if foreign_qualifier?(query, field_name, models)

        build_query(query, quoted_column(models.last.table_name, field_name), rule, models)
      end

      # The models along a path ActiveRecord can join, or nil (RulePath#broken?).
      def joinable_models(association_chain)
        path = PermissionForge::Operators::RulePath.follow(@model_class, association_chain)
        path.models unless path.broken?
      end

      # A join rule's field_name qualified with a table that is none of the
      # rule's own (RuleColumn::UNKNOWN: an alias ActiveRecord gives a table
      # joined twice, or a table the query does not join at all). The joined
      # query names its tables and aliases in its SQL; a qualifier it does not
      # name would make the database reject the query, so the rule matches
      # nothing instead of raising for every holder.
      def foreign_qualifier?(query, field_name, models)
        qualifier = field_name.to_s.split('.')[-2]
        return false unless qualifier
        return false unless PermissionForge::Operators::RuleColumn.find(field_name, models).equal?(PermissionForge::Operators::RuleColumn::UNKNOWN)

        !query.to_sql.include?(@model_class.connection.quote_table_name(qualifier))
      end

      # Quotes a column reference with the connection's identifier quoting.
      # A dotted field_name is treated as already-qualified path segments and
      # each segment is quoted independently.
      def quoted_column(table, field_name)
        conn = @model_class.connection
        name = field_name.to_s
        return name.split('.').map { |seg| conn.quote_column_name(seg) }.join('.') if name.include?('.')

        "#{conn.quote_table_name(table)}.#{conn.quote_column_name(name)}"
      end

      def joined(query, join_method, association_chain)
        association_chain.any? ? apply_join_to_query(query, join_method, association_chain) : query
      end

      # @param join_method [Symbol] one of JOIN_METHODS — never a rule's own text
      def apply_join_to_query(query, join_method, association_chain)
        if association_chain.size > 1
          query.public_send(join_method, build_nested_joins_structure(association_chain))
        else
          query.public_send(join_method, association_chain.first.to_sym)
        end
      end

      def build_nested_joins_structure(association_chain)
        structure = {}
        current = structure

        association_chain.each_with_index do |assoc, index|
          current[assoc.to_sym] = {}
          current = current[assoc.to_sym] unless index == association_chain.length - 1
        end

        structure
      end

      # A built-in operator gets its value in the type of the column it is
      # compared with (see Operators::ValueTyping). A value that cannot be one
      # of that column makes the rule match nothing, whatever the database
      # would have made of the comparison. A custom operator's value is passed
      # as it is and its strategy runs. A field_name that is not a name
      # (Operators::RuleColumn.name?) matches nothing under any operator, and
      # one naming a column its table does not have matches nothing under a
      # built-in operator (Operators::ValueTyping.no_column?) — the database
      # would reject the query, and every holder would get an error instead
      # of a denial. So does one qualified with a table that is not there
      # (RuleColumn#unresolvable?), and a rule whose operator the registry
      # does not have (written past the model, or by a newer version).
      def build_query(query, quoted_column, rule, models)
        operator = rule[:operator]
        strategy = strategy_for(operator)
        target = PermissionForge::Operators::RuleColumn.find(rule[:field_name], models)
        return query.none if strategy.nil? || target.unresolvable?

        value = PermissionForge::Operators::ValueTyping.call(operator, formatted_field_value(rule), target)
        return query.none if value.equal?(PermissionForge::Operators::ValueTyping::UNUSABLE)

        strategy.call(query, quoted_column, rule, value)
      end

      # The operator's strategy from the registry — Operators::Registry, or an
      # injected one: anything answering `strategies` (a Hash of them) or
      # `fetch(name)` (a Hash, an object of the host's) — and nil for an
      # operator it does not have, whether it answers nil or raises for one
      # (ArgumentError as Registry.fetch does, KeyError as a Hash does).
      def strategy_for(operator)
        registry = @operator_registry
        return registry.strategies[operator] if registry.respond_to?(:strategies)

        registry.fetch(operator)
      rescue ArgumentError, KeyError
        nil
      end

      # The only magic value is 'current_user', substituted with the current
      # user's id where one value is compared (in a list it is an element like
      # any other). Every other field_value reaches ValueTyping as it is
      # written, and what comes back is quoted by the adapter — rule text is
      # never interpolated into SQL.
      def formatted_field_value(rule)
        value = rule[:field_value]
        return value unless PermissionForge::Operators::ValueTyping.current_user?(rule[:operator], value)

        raise ArgumentError, 'current_user is nil but rule requires current_user substitution' unless @current_user

        @current_user.id
      end
    end
  end
end
