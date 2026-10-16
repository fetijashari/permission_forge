# frozen_string_literal: true

require 'digest'

module PermissionForge
  module Services
    # Level 3 — Postgres Row-Level Security policy generation.
    #
    # Builds the DDL for one protected model: enable/force RLS plus four
    # policies (SELECT/UPDATE/DELETE share a USING expression; INSERT is
    # WITH CHECK (true) because app-level rules never gate creation).
    #
    # The USING expression is a hybrid of static and dynamic SQL:
    #   - MEMBERSHIP is dynamic — EXISTS subqueries against
    #     permission_set_users / permission_sets evaluated per statement, so
    #     assigning or revoking a user NEVER requires a policy resync.
    #   - RULE CONTENT is static — each granting set's active FILTER-type rules
    #     are compiled to SQL at generation time as
    #     (NOT member(set) OR (rule1 AND rule2 ...)) conjuncts. Editing rule
    #     rows requires `rake permission_forge:rls:sync` (drift is detected via
    #     a digest stored as the SELECT policy's comment).
    #
    # Semantics parity with the application layer:
    #   - view_all/modify_all in a granting set bypasses rules; a muting set
    #     with view_all/modify_all cancels that bypass (both checked
    #     dynamically). Only a resource row in effect counts (r.is_active,
    #     ps.is_active), and with tenancy on only one of the row's tenant: a
    #     view_all grant in tenant A never bypasses the rules on tenant B's
    #     rows, nor on rows of no tenant (narrower than an ambient-tenant app
    #     build there, never wider).
    #   - A granting set's rules are compiled whatever the set's and its
    #     resource row's is_active; the membership EXISTS reads both states
    #     per statement, so switching a set or a resource off or on needs no
    #     re-sync and the policy is never wider than the app layer in between.
    #   - A user in no rule-bearing set sees all rows (rules only restrict).
    #   - Muting sets contribute no rules; conditional sets' rules are included
    #     (more restrictive than the app, never less — documented).
    #   - Missing session variable follows nil_user_strategy: :bypass allows,
    #     :deny/:raise hides every row.
    #   - A rule's value is typed for its column by the app layer's own
    #     Operators::ValueTyping; a value the column cannot hold, or a column
    #     the table does not have, compiles to FALSE, as the app layer matches
    #     nothing for it (see RlsOperatorSql).
    #   - Join-type rules and dotted field names are NOT translatable — they are
    #     reported in :skipped_rules, never silently dropped. So are the rules
    #     of a Resource named after an STI subclass of the model: a policy is
    #     per table and compiled for the class that includes the concern, so
    #     those rules (which the app layer applies to the subclass, see
    #     ResourceChain) hold at the application layer only.
    #
    # This service only BUILDS SQL strings (testable on any adapter);
    # PermissionForge::RLS executes them against Postgres.
    #
    # @api private
    class RlsPolicyGenerator
      POLICY_NAMES = {
        select: 'permission_forge_select',
        insert: 'permission_forge_insert',
        update: 'permission_forge_update',
        delete: 'permission_forge_delete'
      }.freeze

      DIGEST_COMMENT_PREFIX = 'permission_forge digest: '

      # Bumped whenever the generated SQL *shape* changes (not just rule data),
      # so existing installs get a drift warning and re-sync after upgrading.
      # 3: what a rule compiles to follows the app layer — typed values, ILIKE,
      # include_nulls only for the operators that honour it there.
      # 4: the view_all bypass needs the resource row to be active and, with
      # tenancy on, in the row's tenant.
      # 5: a rule set's membership EXISTS joins its resource row and needs it
      # active; the rules are compiled whatever the row's — or the set's —
      # state (the set's is_active was already read live).
      # 6: a rule naming a column the table does not have compiles to FALSE
      # (the sync failed on it), as the app layer matches nothing for it.
      GENERATOR_VERSION = 6

      include RlsOperatorSql

      def self.call(model_class:, configuration: PermissionForge.configuration)
        new(model_class: model_class, configuration: configuration).call
      end

      def initialize(model_class:, configuration: PermissionForge.configuration)
        @model_class = model_class
        @configuration = configuration
        @conn = model_class.connection
        @skipped_rules = []
      end

      # @return [Hash] { table:, statements: Array<String>, digest:, skipped_rules: }
      def call
        note_subclass_rules
        statements = [
          "ALTER TABLE #{quoted_table} ENABLE ROW LEVEL SECURITY",
          "ALTER TABLE #{quoted_table} FORCE ROW LEVEL SECURITY",
          *POLICY_NAMES.values.map { |name| "DROP POLICY IF EXISTS #{name} ON #{quoted_table}" },
          *policy_statements,
          comment_statement
        ]

        { table: table_name, statements: statements, digest: digest, skipped_rules: @skipped_rules }
      end

      # Canonical fingerprint of everything static in the policy. Stored as the
      # SELECT policy's comment; a mismatch at boot means rules changed since
      # the last sync.
      def digest
        parts = [
          GENERATOR_VERSION,
          @configuration.nil_user_strategy,
          @configuration.rls_session_variable,
          table_name,
          tenant_predicate_sql,
          rule_sets.map { |set| [set[:id], set[:resource_id], set[:rules].map { |r| rule_fingerprint(r) }.sort] }.sort
        ]
        Digest::SHA256.hexdigest(parts.inspect)
      end

      private

      # Adapter connection used for quoting by RlsOperatorSql helpers too.
      def connection
        @conn
      end

      def table_name
        @model_class.table_name
      end

      def quoted_table
        @conn.quote_table_name(table_name)
      end

      def resource_name
        @model_class.name
      end

      def policy_statements
        using = using_expression
        [
          "CREATE POLICY #{POLICY_NAMES[:select]} ON #{quoted_table} FOR SELECT USING (#{using})",
          "CREATE POLICY #{POLICY_NAMES[:insert]} ON #{quoted_table} FOR INSERT WITH CHECK (true)",
          "CREATE POLICY #{POLICY_NAMES[:update]} ON #{quoted_table} FOR UPDATE USING (#{using}) WITH CHECK (true)",
          "CREATE POLICY #{POLICY_NAMES[:delete]} ON #{quoted_table} FOR DELETE USING (#{using})"
        ]
      end

      def comment_statement
        "COMMENT ON POLICY #{POLICY_NAMES[:select]} ON #{quoted_table} IS " \
          "#{@conn.quote("#{DIGEST_COMMENT_PREFIX}#{digest}")}"
      end

      # :bypass  -> uid IS NULL OR (view_all OR rules)
      # :deny/:raise -> uid IS NOT NULL AND (view_all OR rules)
      # The explicit uid guard matters: with a NULL uid every membership EXISTS
      # is false, which would make the rules conjunction vacuously TRUE — the
      # deny strategies must therefore hide rows before that branch is reached.
      def using_expression
        guarded = "(#{view_all_bypass_sql} OR #{rules_conjunction_sql})"
        if @configuration.nil_user_strategy == :bypass
          "((#{uid_sql}) IS NULL OR #{guarded})"
        else
          "((#{uid_sql}) IS NOT NULL AND #{guarded})"
        end
      end

      # current_setting(var, true) returns NULL when unset but '' after RESET,
      # hence the NULLIF. Cast to the real user_id column type so uuid or
      # bigint PKs both work.
      def uid_sql
        var = @conn.quote(@configuration.rls_session_variable)
        "NULLIF(current_setting(#{var}, true), '')::#{user_id_cast_type}"
      end

      def user_id_cast_type
        PermissionForge::SchemaRead.column(PermissionForge::PermissionSetUser, 'user_id')&.sql_type || 'bigint'
      end

      # Granting-set view_all/modify_all bypasses rules; a muting set with
      # view_all/modify_all cancels the bypass. Both checked dynamically.
      #
      # GDPR/consent guard: activation conditions (session flag / IP / login
      # hours) cannot be evaluated inside a database policy, so only
      # UNCONDITIONAL sets may grant the bypass — a consent-gated set granting
      # view_all must never widen DB-level access while its condition is
      # unmet. Muting sets keep canceling regardless (restrictive direction is
      # always safe).
      def view_all_bypass_sql
        "(#{view_all_exists_sql(muting: false)} AND NOT #{view_all_exists_sql(muting: true)})"
      end

      def view_all_exists_sql(muting:)
        <<~SQL.squish
          EXISTS (
            SELECT 1 FROM #{psu_table} psu
            JOIN #{ps_table} ps ON ps.id = psu.permission_set_id
            JOIN #{resources_table} r ON r.permission_set_id = ps.id
            WHERE psu.user_id = (#{uid_sql})
              AND #{assignment_active_sql}
              AND ps.is_active = TRUE AND ps.is_muting = #{muting ? 'TRUE' : 'FALSE'}
              #{"AND #{unconditional_set_sql}" unless muting}
              AND r.name = #{@conn.quote(resource_name)}
              AND r.is_active = TRUE
              #{tenant_predicate_sql}
              AND (r.view_all = TRUE OR r.modify_all = TRUE)
          )
        SQL
      end

      # Ties the resource row to the protected row's tenant, when tenancy is
      # on and both tables have the tenant column (SchemaRead: read again once
      # before "no"): `AND r.account_id =
      # "customers"."account_id"`. A NULL tenant on either side matches
      # nothing. Empty otherwise (no tenant to compare).
      def tenant_predicate_sql
        column = @configuration.tenant_enabled? && @configuration.resolved_tenant_column.to_s
        return '' unless column && [@model_class, PermissionForge::Resource].all? { |klass| SchemaRead.column?(klass, column, ignored: false) }

        quoted = @conn.quote_column_name(column)
        "AND r.#{quoted} = #{quoted_table}.#{quoted}"
      end

      # Mirrors PermissionSet.unconditional (activation conditions absent).
      def unconditional_set_sql
        "(ps.requires_session_flag IS NULL OR ps.requires_session_flag = '') " \
          "AND (ps.allowed_ips IS NULL OR ps.allowed_ips = '') " \
          'AND ps.allowed_hours_start IS NULL'
      end

      # One conjunct per rule-bearing granting set:
      #   (NOT member(set) OR (rule1 AND rule2 ...))
      # A user in none of these sets passes every conjunct (rules only
      # restrict); a member must satisfy that set's rules. TRUE when no set has
      # translatable rules.
      def rules_conjunction_sql
        conjuncts = rule_sets.map do |set|
          "(NOT #{membership_exists_sql(set[:id], set[:resource_id])} OR (#{set[:rules].map { |r| rule_sql(r) }.join(' AND ')}))"
        end
        return 'TRUE' if conjuncts.empty?

        "(#{conjuncts.join(' AND ')})"
      end

      # Member of the set, with the set and the resource row the rules belong
      # to both active, as the app layer reads them: a switched-off resource
      # holds nobody to its rules.
      def membership_exists_sql(set_id, resource_id)
        <<~SQL.squish
          EXISTS (
            SELECT 1 FROM #{psu_table} psu
            JOIN #{ps_table} ps ON ps.id = psu.permission_set_id
            JOIN #{resources_table} r ON r.id = #{Integer(resource_id)} AND r.is_active = TRUE
            WHERE psu.user_id = (#{uid_sql})
              AND psu.permission_set_id = #{Integer(set_id)}
              AND ps.is_active = TRUE
              AND #{assignment_active_sql}
          )
        SQL
      end

      def assignment_active_sql
        clauses = ['(psu.expires_at IS NULL OR psu.expires_at > now())']
        clauses << 'psu.is_active = TRUE' if PermissionForge::SchemaRead.column?(PermissionForge::PermissionSetUser, 'is_active', ignored: false)
        clauses.join(' AND ')
      end

      def psu_table
        @conn.quote_table_name(PermissionForge::PermissionSetUser.table_name)
      end

      def ps_table
        @conn.quote_table_name(PermissionForge::PermissionSet.table_name)
      end

      def resources_table
        @conn.quote_table_name(PermissionForge::Resource.table_name)
      end

      # A rule the app layer matches nothing for (Operators::RuleProblem: the
      # one taxonomy — a join type or operator this version does not know, a
      # path no join is built through, a qualifier naming no table, a column
      # the table does not have, a value it cannot hold) makes the rule FALSE
      # — NULL rows included.
      def rule_sql(rule)
        return 'FALSE' if Operators::RuleProblem.for(rule)

        operator, field_name = rule.values_at(:operator, :field_name)
        value = typed_value(operator, rule.field_value, Operators::RuleColumn.find(field_name, [@model_class]))
        return 'FALSE' if value.equal?(UNUSABLE)

        col = "#{quoted_table}.#{@conn.quote_column_name(field_name)}"
        base = OPERATOR_SQL.fetch(operator).call(col, value, self)
        rule.include_nulls? && NULL_INCLUDING.include?(operator) ? "((#{base}) OR #{col} IS NULL)" : "(#{base})"
      end

      # Granting sets with active, translatable FILTER-type rules on this
      # resource, whatever the set's or the resource row's own is_active (the
      # membership EXISTS reads both per statement: a set switched off at
      # sync time and on later must not be wider than the app layer until the
      # next re-sync). Join-type rules and dotted field names go to
      # :skipped_rules — bounded coverage is reported, never silent.
      def rule_sets
        @rule_sets ||= PermissionForge::Resource.where(name: resource_name).filter_map do |resource|
          permission_set = resource.permission_set
          next unless permission_set && !permission_set.is_muting

          rules = partition_rules(resource, permission_set)
          next if rules.empty?

          { id: permission_set.id, resource_id: resource.id, rules: rules }
        end
      end

      def partition_rules(resource, permission_set)
        resource.permission_set_rules.active.filter_map do |rule|
          reason = untranslatable_reason(rule)
          if reason
            @skipped_rules << { permission_set: permission_set.name, rule: rule.name, reason: reason }
            next
          end

          rule
        end
      end

      # The active rules of resources named after the model's loaded STI
      # subclasses, in effect in a granting set: not compiled (see the class
      # comment), reported.
      def note_subclass_rules
        names = subclass_names
        return if names.empty?

        subclass_rules(names).each do |rule|
          @skipped_rules << { permission_set: rule.permission_set.name, rule: rule.name, reason: :sti_subclass_resource }
        end
      end

      # The loaded descendants on this table (a subclass with a table of its
      # own is another policy's business), minus one that answers to one of
      # the model's own names (a test double, a renamed subclass).
      def subclass_names
        subclasses = @model_class.descendants.select { |klass| klass.table_name == table_name }
        subclasses.filter_map(&:name).uniq - ResourceChain.names(@model_class).map(&:to_s)
      end

      # The active rules of the resource rows in effect (Resource.in_effect),
      # in granting sets, named after the model's loaded STI subclasses.
      def subclass_rules(names)
        resources = PermissionForge::Resource.in_effect.where(name: names)
                                             .where(PermissionForge::PermissionSet.table_name => { is_muting: false })
        PermissionForge::PermissionSetRule.active.where(resource_id: resources.select(:id)).includes(:permission_set)
      end

      # nil for a rule that is compiled, else why it is skipped (reported in
      # :skipped_rules). A rule the app layer matches nothing for
      # (Operators::RuleProblem) is compiled whatever it is — to FALSE
      # (rule_sql) — never skipped, which would leave the policy wider than
      # the app layer. An operator the app layer has (a custom one registered
      # in Operators::Registry) but this module has no SQL for is skipped.
      def untranslatable_reason(rule)
        return if Operators::RuleProblem.for(rule)
        return :join_rule if rule.join_rule?
        return :dotted_field_name if rule.field_name.to_s.include?('.')
        return :unknown_operator unless OPERATOR_SQL.key?(rule.operator)

        nil
      end

      # The compiled SQL is part of it: what a rule compiles to also depends on
      # the model (the column's type, an enum's stored values). All text, so
      # the fingerprints of one set sort whatever the rules are.
      def rule_fingerprint(rule)
        rule.values_at(:operator, :field_name, :field_value, :include_nulls).map(&:to_s) << rule_sql(rule)
      end
    end
  end
end
