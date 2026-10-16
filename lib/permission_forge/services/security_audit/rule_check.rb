# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Record (row-level) rules: whether the app's query scoping applies them,
      # rules that match nothing (Operators::RuleProblem, the one taxonomy —
      # each kind lands in one finding), rules naming a table of another
      # model, rules View All makes pointless, and likely misconfigurations.
      class RuleCheck < BaseCheck
        TEXT_OPERATORS = %w[contains starts_with ends_with].freeze

        # The kinds of Operators::RuleProblem each finding reports: one
        # finding per kind. A new kind goes in exactly one list (the
        # taxonomy guard fails for a kind no finding names).
        FINDING_KINDS = {
          missing_rule_columns: %i[missing_column unknown_association unjoinable_association unknown_table],
          unknown_rule_operators: %i[unknown_operator unknown_join_type],
          unusable_rule_values: %i[unusable_value],
          foreign_table_filter_rules: %i[foreign_table],
          encrypted_rule_columns: %i[encrypted_column],
          non_text_pattern_rules: %i[pattern_on_non_text]
        }.freeze

        def call
          return [no_rules] unless active_rules.exists?

          [unenforced, missing_columns, unknown_operators, unusable_values, foreign_table_filters, encrypted_columns,
           non_text_patterns, secret_columns, foreign_table_names, bypassed, text_operator_on_ids].compact
        end

        private

        def active_rules
          PermissionForge::PermissionSetRule.active
        end

        # The advice follows the setting: with auto_query_scoping on, rules
        # are all that is missing.
        def no_rules
          advice = if configuration.auto_query_scoping_enabled?
                     'otherwise add rules (auto_query_scoping is on, so a filter rule applies to every query).'
                   else
                     'otherwise add rules and enable auto_query_scoping.'
                   end
          finding(:info, :no_rules, 'No record rules are in use',
                  'Anyone with read access to a resource sees every record of it. That is fine if your app ' \
                  "limits records itself; #{advice}")
        end

        # What the admin's Home shows: the same rules (AttentionItems).
        def attention
          @attention ||= PermissionForge::Admin::AttentionItems.new(configuration: configuration)
        end

        def unenforced
          findings = attention.unenforced_rules
          return if findings.empty?

          held = findings.any? { |item| item.people_count.positive? }
          finding(held ? :high : :medium, :unenforced_rules, 'Record rules are not applied to every query',
                  unenforced_detail, items: findings.map { |item| unenforced_item(item) })
        end

        def unenforced_detail
          if configuration.auto_query_scoping_enabled?
            'These are join rules: auto_query_scoping skips them, so only find_by / permission_scoped apply ' \
              'them. Route the queries through Model.permission_scoped.'
          else
            'auto_query_scoping is off, so these rules only apply to find_by / permission_scoped; a bare ' \
              'where / all / association query returns every record. Enable auto_query_scoping = :filter_only ' \
              '(see docs/query-scoping.md), and unscoped_query_detection to find the call sites.'
          end
        end

        def unenforced_item(item)
          "#{item.permission_set.name} › #{item.resource.name}: #{item.rule_count} rule(s) · " \
            "#{people_label(item.people_count)}"
        end

        # The rules in effect Home lists as matching nothing
        # (AttentionItems#broken_rules), of the kinds one finding reports.
        def broken(code)
          attention.broken_rules.select { |item| FINDING_KINDS.fetch(code).include?(item.problem.kind) }
        end

        # The finding's severity: the first while people hold one of the rules, else the second.
        def weight(findings, held, unheld)
          findings.any? { |item| item.people_count.positive? } ? held : unheld
        end

        # Rules saved before PermissionSetRule checked the column, the table
        # and the path, or written past the model (the tables are shared with
        # other applications).
        def missing_columns
          findings = broken(:missing_rule_columns)
          return if findings.empty?

          finding(weight(findings, :high, :medium), :missing_rule_columns,
                  'Rules naming a column, table or association that does not exist',
                  'The field name of these rules is not a column of their table (or not a name: a trailing or doubled ' \
                  'dot), names a table this database does not have, or their association path names an association ' \
                  'their model does not have (or an empty segment) or one a join cannot be built through ' \
                  '(polymorphic, a scope that takes the record — also along a :through —, a :through, :source or ' \
                  'inverse_of naming nothing, a class that cannot be loaded) — a typo, or a column or association ' \
                  'since renamed or removed. Such a rule ' \
                  'matches nothing: everyone it applies to is denied every record of the resource. Correct the rule ' \
                  'or remove it (see "Using the wrong field name" in docs/row-level-rules.md).',
                  items: findings.map { |item| rule_item(item.rule) })
        end

        # Rules whose operator or join type this version does not have:
        # written by a newer version (a rolling deploy), by another
        # application on the shared tables, or past the model.
        def unknown_operators
          findings = broken(:unknown_rule_operators)
          return if findings.empty?

          finding(weight(findings, :high, :medium), :unknown_rule_operators,
                  'Rules with an operator or join type this version does not know',
                  'The operator or join type of these rules is none this version of PermissionForge has — written ' \
                  'by a newer version (a rolling deploy), by another application on the shared tables, or past the ' \
                  'model. Such a rule matches nothing: everyone it applies to is denied every record of the resource ' \
                  '(never an error). Finish the upgrade, or correct the rule.',
                  items: findings.map { |item| unknown_operator_item(item) })
        end

        def unknown_operator_item(item)
          rule = item.rule
          note = " (join type #{rule.join_type.inspect})" if item.problem.kind == :unknown_join_type
          rule_item(rule, note)
        end

        def unusable_values
          findings = broken(:unusable_rule_values)
          return if findings.empty?

          finding(weight(findings, :medium, :low), :unusable_rule_values, 'Rules that match nothing',
                  'The value of these rules is not one their column can hold: text on a number column, a word that ' \
                  'is no boolean, an unknown enum label, a date that is not ISO 8601 (on MySQL and SQLite), a list ' \
                  'or range with the wrong number of values. Such a rule matches nothing: everyone it applies to is ' \
                  'denied every record of the resource. Correct the rule or remove it (see "How Values Are ' \
                  'Compared" in docs/row-level-rules.md).',
                  items: findings.map { |item| rule_item(item.rule) })
        end

        # Filter rules qualified with another model's table (RuleProblem
        # :foreign_table): a filter rule compares its model's own table, so
        # such a rule matches nothing (it raised in every query of its holders).
        def foreign_table_filters
          findings = broken(:foreign_table_filter_rules).presence or return

          finding(weight(findings, :high, :medium), :foreign_table_filter_rules,
                  'Filter rules naming a table of another model',
                  'The field name of these filter rules is qualified with the table of another model. A filter rule ' \
                  'compares its own model\'s table, so such a rule matches nothing: everyone it applies to is denied ' \
                  'every record of the resource. For a column of another table, use a join rule (a join type and the ' \
                  'relationship path in field_accessor_path).', items: findings.map { |item| rule_item(item.rule) })
        end

        # Rules comparing a value with an encrypted attribute (RuleProblem
        # :encrypted_column): the column holds ciphertext, so such a rule
        # matches nothing. Saved before the host encrypted the attribute, or
        # written past the model.
        def encrypted_columns
          findings = broken(:encrypted_rule_columns).presence or return

          finding(weight(findings, :high, :medium), :encrypted_rule_columns,
                  'Rules comparing an encrypted attribute',
                  'These rules compare a value with an attribute the model declares with `encrypts` (Active Record ' \
                  'encryption): the column holds its ciphertext, so the comparison never matches and everyone the rule ' \
                  'applies to is denied every record of the resource. Only is_null / is_not_null can be asked of such a ' \
                  'column. Compare another column, or remove the rule (see "Encrypted attributes" in ' \
                  'docs/row-level-rules.md).', items: findings.map { |item| rule_item(item.rule) })
        end

        # LIKE rules on a column no pattern can be matched against (RuleProblem
        # :pattern_on_non_text): a json column, or on PostgreSQL any column
        # that is not text. Reported as unusable_rule_values before 0.15.
        def non_text_patterns
          findings = broken(:non_text_pattern_rules).presence or return

          finding(weight(findings, :medium, :low), :non_text_pattern_rules,
                  'Pattern rules on a column that is not text',
                  'These rules use contains, not_contains, starts_with or ends_with on a column that holds no text ' \
                  '(a number, a date, a boolean, a uuid or a json document on PostgreSQL; a json column everywhere): such ' \
                  'a rule matches nothing, so everyone it applies to is denied every record of the resource. Use a ' \
                  'condition that compares values (equal, in, between), or remove the rule.',
                  items: findings.map { |item| rule_item(item.rule) })
        end

        # Rules in effect comparing a column that holds a secret
        # (PermissionForge::SecretColumns) — what Home lists
        # (AttentionItems#secret_rules). Stored before the model refused them;
        # they still apply. The item leaves the value out: it is a guess at the secret.
        def secret_columns
          findings = attention.secret_rules.presence or return

          finding(:medium, :secret_rule_columns, 'Rules comparing a column that holds a secret',
                  'These rules compare a password digest, a token, an `encrypted_*` column or a secret ' \
                  '(config.rule_secret_column_patterns; an attribute declared with `encrypts` is ' \
                  'encrypted_rule_columns). They still apply, but who can read which record tells the ' \
                  'secret apart, and the rule value is stored and shown in the admin and the API. Compare another ' \
                  'column, or remove the rule; a new rule on such a column is refused.',
                  items: findings.map { |item| secret_rule_item(item.rule) })
        end

        def secret_rule_item(rule)
          resource = rule.resource
          path = rule.field_accessor_path.presence if rule.join_rule?
          "#{resource.permission_set.name} › #{[resource.name, path, rule.field_name].compact.join('.')}: #{rule.name} · " \
            "#{people(resource.permission_set_id)}"
        end

        # Join rules in effect whose field name is qualified with a real table
        # that is none of the rule's (Operators::RuleColumn::FOREIGN): the
        # query has to join that table itself (a default scope's join) — the
        # value is compared untyped, and where the query does not join it the
        # rule matches nothing. (A filter rule's is a RuleProblem.)
        def foreign_table_names
          rules = rules_in_effect.select { |rule| foreign_table?(rule) }
          return if rules.empty?

          finding(:info, :foreign_table_names, 'Join rules naming a table of another model',
                  'The field name of these rules is qualified with a table that is none of the rule\'s — not the ' \
                  'model\'s, nor one along its relationship path — so it is left to the database: the query has to ' \
                  'join that table itself (where it does not, the rule matches nothing), and the value is compared as ' \
                  'text. Name the relationship in field_accessor_path instead, so the column is checked and the value ' \
                  'typed.', items: rules.map { |rule| rule_item(rule) })
        end

        def foreign_table?(rule)
          rule.join_rule? && Operators::RuleColumn.for_rule(rule)&.foreign?
        end

        # The rules applied right now (AttentionItems#rules_in_effect).
        def rules_in_effect
          attention.rules_in_effect
        end

        # "Sales › Customer.supplier.owner_id equal "no": Off · 1 person"
        def rule_item(rule, note = nil)
          resource = rule.resource
          path = rule.field_accessor_path.presence if rule.join_rule?
          field = [resource.name, path, rule.field_name].compact.join('.')
          "#{resource.permission_set.name} › #{field} #{rule.operator} #{rule.field_value.inspect}: #{rule.name}#{note} · " \
            "#{people(resource.permission_set_id)}"
        end

        def bypassed
          rules = active_rules.includes(resource: :permission_set).select { |rule| rule.resource&.rules_bypassed? }
          return if rules.empty?

          finding(:low, :bypassed_rules, 'Rules ignored because View All is on',
                  'View All / Modify All skip these rules. Remove the rule or the bypass so the setup says what it does.',
                  items: rules.map { |rule| "#{rule.resource.permission_set.name} › #{rule.resource.name}: #{rule.name}" })
        end

        def text_operator_on_ids
          rules = active_rules.where(operator: TEXT_OPERATORS).includes(:resource)
                              .select { |rule| rule.field_name.to_s.end_with?('id') }
          return if rules.empty?

          finding(:low, :text_operator_on_ids, 'Text matching on id columns',
                  'contains / starts_with / ends_with on an id matches more records than intended (12 contains 1). ' \
                  'Use equal or in.', items: rules.map { |rule| "#{rule.resource.name}.#{rule.field_name}: #{rule.name}" })
        end
      end
    end
  end
end
