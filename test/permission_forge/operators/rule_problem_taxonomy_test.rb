# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'
require_relative '../../support/rule_problem_fixtures'

module PermissionForge
  module Operators
    # G2 — the one taxonomy of "a rule that matches nothing". For every kind
    # in RuleProblem::KINDS (a fixture per kind in
    # test/support/rule_problem_fixtures.rb; a kind without one fails):
    #
    # - the model refuses a new rule with the kind's message (where the kind
    #   is refused on save: a value the column cannot hold is documented as
    #   valid to save),
    # - RuleProblem.for names a row written past the model,
    # - the applier matches nothing for its holders — never a raise,
    # - Home lists it (AttentionItems#broken_rules), the audit lists it,
    # - the RLS policy compiles it to FALSE,
    # - its validation message exists in every locale,
    # - a row written before the check stays editable in its other attributes.
    class RuleProblemTaxonomyTest < ActiveSupport::TestCase
      include RuleProblemFixtures

      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @user = create_user
        @set = create_permission_set(name: 'Sales')
        create_permission_set_user(user: @user, permission_set: @set)
        @resources = {}
        @customer = create_customer(name: 'mine')
        @path_record = PfRulePathRecord.create!(label: 'mine')
        Current.user = @user
      end

      teardown do
        Current.user = nil
      end

      test 'every kind has a fixture, and every fixture is a kind' do
        assert_equal RuleProblem::KINDS.sort, FIXTURES.keys.sort
        assert_equal %i[missing_column unknown_association unjoinable_association unknown_operator unknown_join_type
                        unknown_table unusable_value].sort, RuleProblem::KINDS.sort
      end

      FIXTURES.each_key do |kind|
        test "#{kind}: a row written past the model is named, denies, is listed, compiles to FALSE" do
          rule = broken_rule(kind, permission_set: @set, resource: resource_for(kind))
          problem = RuleProblem.for(rule)

          assert_equal kind, problem&.kind, "RuleProblem.for names the kind (#{problem.inspect})"
          assert_matches_nothing(kind, rule)
          assert_includes Admin::AttentionItems.new.broken_rules.map { |item| item.rule.id }, rule.id, 'Home lists it'
          assert_audit_names(rule)
          assert_rls_false(kind, rule)
          assert_message_in_every_locale(problem)
        end

        test "#{kind}: a new rule is #{FIXTURES[kind][:refused] ? 'refused with the problem\'s message' : 'accepted, as documented'}" do
          rule = new_broken_rule(kind, permission_set: @set, resource: resource_for(kind))
          refused = FIXTURES.fetch(kind)[:refused]

          if refused
            assert_not rule.valid?
            assert_includes rule.errors[refused], RuleProblem.for(rule).validation_message
          else
            assert rule.valid?, rule.errors.full_messages.inspect
          end
        end

        test "#{kind}: a row written before the check stays editable in its other attributes" do
          rule = broken_rule(kind, permission_set: @set, resource: resource_for(kind))
          rule.name = 'Renamed'

          assert rule.valid?, rule.errors.full_messages.inspect
          assert rule.save
        end
      end

      test 'what the fixture names is refused again when it changes' do
        rule = broken_rule(:unknown_operator, permission_set: @set, resource: resource_for(:unknown_operator))
        rule.operator = 'regexp'

        assert_not rule.valid?
        assert rule.errors[:operator].any?

        rule = broken_rule(:unknown_join_type, permission_set: @set, resource: resource_for(:unknown_join_type))
        rule.join_type = 'outer'

        assert_not rule.valid?
        assert rule.errors[:join_type].any?
      end

      private

      def resource_for(kind)
        name = fixture_model_name(kind)
        @resources[name] ||= create_resource(permission_set: @set, name: name, read_access: true)
      end

      def model_for(kind)
        fixture_model_name(kind).constantize
      end

      def record_for(kind)
        fixture_model_name(kind) == 'Customer' ? @customer : @path_record
      end

      # The holder's queries: permission_scoped lets nothing through, find_by
      # denies the record, and nothing raises but the denial.
      def assert_matches_nothing(kind, rule)
        @user.invalidate_permissions
        model = model_for(kind)
        rules = cached_rules(model)

        assert_equal [rule.name], rules.map { |hash| hash[:name] }, 'the hash carries the rule'
        assert_empty Services::PermissionRuleApplier.scope(model_class: model, rules: rules, current_user: @user).to_a
        assert_denied(kind, model)
      end

      def assert_denied(kind, model)
        assert_empty model.permission_scoped.to_a, "#{kind}: permission_scoped"
        assert_raises(NotAuthorizedError, "#{kind}: find_by") { model.find_by(id: record_for(kind).id) }
      end

      def cached_rules(model)
        @user.permissions_hash_for(model.name.to_sym)[:permission_set_rules]
      end

      def assert_audit_names(rule)
        findings = Services::SecurityAudit.call.findings.select { |finding| finding.items.any? { |item| item.include?(rule.name) } }

        assert_not_empty findings, 'rake permission_forge:audit names the rule'
        assert findings.all? { |finding| %i[high medium].include?(finding.severity) },
               "a held rule that matches nothing is at least medium: #{findings.map(&:severity)}"
      end

      # The policy for the set's resource: the rule is compiled, to FALSE,
      # and not reported as skipped.
      def assert_rls_false(kind, rule)
        result = Services::RlsPolicyGenerator.call(model_class: model_for(kind))
        select_policy = result[:statements].find { |statement| statement.match?(/\ACREATE POLICY permission_forge_select\b/) }

        assert_match(/OR \(FALSE\)\)/, select_policy, "#{kind}: the rule compiles to FALSE")
        assert_not_includes result[:skipped_rules].map { |skipped| skipped[:rule] }, rule.name, 'not skipped: compiled'
      end

      def assert_message_in_every_locale(problem)
        %w[en sq mk].each do |locale|
          message = I18n.t("permission_forge.validations.permission_set_rule.#{problem.message_key}", locale: locale, default: nil)

          assert message.present?, "#{locale}: validations.permission_set_rule.#{problem.message_key}"
        end
      end
    end
  end
end
