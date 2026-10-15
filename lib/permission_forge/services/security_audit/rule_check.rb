# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Record (row-level) rules: whether the app's query scoping applies them,
      # rules naming a column their table does not have, rules whose value
      # makes them match nothing, rules View All makes pointless, and likely
      # misconfigurations.
      class RuleCheck < BaseCheck
        TEXT_OPERATORS = %w[contains starts_with ends_with].freeze
        # What `current_user` is typed as here: an id is a number or its text,
        # whoever the user is, and never a boolean or a date.
        ANY_USER_ID = 0

        def call
          return [no_rules] unless active_rules.exists?

          [unenforced, missing_columns, unusable_values, bypassed, text_operator_on_ids].compact
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

        # Rules saved before PermissionSetRule checked the column and the
        # path, or written past the model (the tables are shared with other
        # applications): the same rules as the admin's Home lists
        # (AttentionItems#broken_rules, Operators::RuleProblem).
        def missing_columns
          findings = attention.broken_rules
          return if findings.empty?

          held = findings.any? { |item| item.people_count.positive? }
          finding(held ? :high : :medium, :missing_rule_columns, 'Rules naming a column or association that does not exist',
                  'The field name of these rules is not a column of their table, or their association path names an ' \
                  'association their model does not have (or an empty segment) or one a join cannot be built through ' \
                  '(polymorphic, a scope that takes the record — also along a :through —, a :through, :source or ' \
                  'inverse_of naming nothing, a class that cannot be loaded) — a typo, or a column or association ' \
                  'since renamed or removed. Such a rule ' \
                  'matches nothing: everyone it applies to is denied every record of the resource. Correct the rule ' \
                  'or remove it (see "Using the wrong field name" in docs/row-level-rules.md).',
                  items: findings.map { |item| unusable_item(item.rule) })
        end

        def unusable_values
          rules = rules_in_effect.select { |rule| unusable_value?(rule) }
          return if rules.empty?

          held = rules.any? { |rule| held?(rule) }
          finding(held ? :medium : :low, :unusable_rule_values, 'Rules that match nothing',
                  'The value of these rules is not one their column can hold: text on a number column, a word that ' \
                  'is no boolean, an unknown enum label, a date that is not ISO 8601 (on MySQL and SQLite), a list ' \
                  'or range with the wrong number of values — or the field name is not a name (a trailing or ' \
                  'doubled dot). Such a rule matches nothing: everyone it applies to is denied every record of ' \
                  'the resource. Correct the rule or remove it (see "How Values Are Compared" in ' \
                  'docs/row-level-rules.md).',
                  items: rules.map { |rule| unusable_item(rule) })
        end

        def held?(rule)
          people_counts.fetch(rule.resource.permission_set_id, 0).positive?
        end

        # The rules applied right now (AttentionItems#rules_in_effect).
        def rules_in_effect
          attention.rules_in_effect
        end

        # Typed the way the application layer types it (Operators::ValueTyping).
        # A model that is not there, or cannot be read, says nothing about the
        # value — that is the integrity check's finding, not one of this check.
        # A missing column or path is missing_columns' finding.
        def unusable_value?(rule)
          target = rule_column(rule)
          return false if target.nil? || target.missing?

          operator = rule.operator
          value = rule.field_value
          value = ANY_USER_ID if Operators::ValueTyping.current_user?(operator, value)
          Operators::ValueTyping.call(operator, value, target).equal?(Operators::ValueTyping::UNUSABLE)
        rescue ActiveRecord::ActiveRecordError, NameError, ArgumentError
          false
        end

        # The column the rule names, found the way PermissionRuleApplier finds
        # it (Operators::RuleColumn.for_rule), once per rule. A rule whose
        # association path cannot be followed has none (nil): it is
        # missing_columns' finding.
        def rule_column(rule)
          @rule_columns ||= {}
          return @rule_columns[rule.id] if @rule_columns.key?(rule.id)

          @rule_columns[rule.id] = Operators::RuleColumn.for_rule(rule)
        end

        def unusable_item(rule)
          resource = rule.resource
          path = rule.field_accessor_path.presence if rule.join_rule?
          field = [resource.name, path, rule.field_name].compact.join('.')
          "#{resource.permission_set.name} › #{field} #{rule.operator} #{rule.field_value.inspect}: #{rule.name} · " \
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
