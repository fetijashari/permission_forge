# frozen_string_literal: true

module PermissionForge
  module Services
    module SecurityAuditChecks
      # Record (row-level) rules: whether the app's query scoping applies them,
      # rules whose value makes them match nothing, rules View All makes
      # pointless, and likely misconfigurations.
      class RuleCheck < BaseCheck
        TEXT_OPERATORS = %w[contains starts_with ends_with].freeze
        # What `current_user` is typed as here: an id is a number or its text,
        # whoever the user is, and never a boolean or a date.
        ANY_USER_ID = 0

        def call
          return [no_rules] unless active_rules.exists?

          [unenforced, unusable_values, bypassed, text_operator_on_ids].compact
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

        def unenforced
          findings = PermissionForge::Admin::AttentionItems.new(configuration: configuration).unenforced_rules
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

        def unusable_values
          rules = rules_in_effect.select { |rule| unusable_value?(rule) }
          return if rules.empty?

          held = rules.any? { |rule| people_counts.fetch(rule.resource.permission_set_id, 0).positive? }
          finding(held ? :medium : :low, :unusable_rule_values, 'Rules that match nothing',
                  'The value of these rules is not one their column can hold: text on a number column, a word that ' \
                  'is no boolean, an unknown enum label, a date that is not ISO 8601 (on MySQL and SQLite), a list ' \
                  'or range with the wrong number of values — or the field name is not a name (a trailing or ' \
                  'doubled dot). Such a rule matches nothing: everyone it applies to is denied every record of ' \
                  'the resource. Correct the rule or remove it (see "How Values Are Compared" in ' \
                  'docs/row-level-rules.md).',
                  items: rules.map { |rule| unusable_item(rule) })
        end

        # Active rules of active resources in active granting sets: the rules
        # that are applied right now (a muting set's rules never are). Not the
        # ones View All skips — nobody is denied by those; they are listed
        # under bypassed_rules.
        def rules_in_effect
          resources = PermissionForge::Resource.in_effect.merge(PermissionForge::PermissionSet.granting)
          active_rules.where(resource_id: resources.select(:id)).includes(resource: :permission_set).order(:resource_id, :id)
                      .reject { |rule| rule.resource.rules_bypassed? }
        end

        # Typed the way the application layer types it (Operators::ValueTyping).
        # A model that is not there, or cannot be read, says nothing about the
        # value — that is the integrity check's finding, not one of this check.
        def unusable_value?(rule)
          target = rule_column(rule)
          return false unless target

          operator = rule.operator
          value = rule.field_value
          value = ANY_USER_ID if Operators::ValueTyping.current_user?(operator, value)
          Operators::ValueTyping.call(operator, value, target).equal?(Operators::ValueTyping::UNUSABLE)
        rescue ActiveRecord::ActiveRecordError, NameError, ArgumentError
          false
        end

        # The column the rule names, found the way PermissionRuleApplier finds
        # it. A rule whose association path cannot be followed is left out: the
        # engine raises for it, it does not match nothing. Tables are checked
        # first: asking a missing one for its columns fails the statement, and
        # with it a transaction the audit may run in.
        def rule_column(rule)
          model = rule.resource.name.safe_constantize
          return unless model.is_a?(Class) && model < ActiveRecord::Base

          path = rule.join_rule? ? rule.field_accessor_path.to_s.split('.') : []
          models = Operators::RuleColumn.models_along(model, path)
          Operators::RuleColumn.find(rule.field_name, models) if models.any? && models.all?(&:table_exists?)
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
