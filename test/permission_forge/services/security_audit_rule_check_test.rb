# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/rule_problem_fixtures'

module PermissionForge
  module Services
    # The rule check reads the one taxonomy (Operators::RuleProblem): each
    # kind lands in exactly one finding, with the row named, and a qualifier
    # that is a real table the query may join itself is an info finding, not
    # a refusal.
    class SecurityAuditRuleCheckTest < ActiveSupport::TestCase
      include RuleProblemFixtures

      setup do
        @config = PermissionForge::Configuration.new
        @config.user_class = 'User'
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: create_user, permission_set: @set)
      end

      def audit
        SecurityAudit.call(configuration: @config, environment: 'test')
      end

      def finding(code) = audit.findings.find { |item| item.code == code }

      test 'an operator or join type this version does not know is its own finding, high while people hold the set' do
        broken_rule(:unknown_operator, permission_set: @set, resource: @resource)
        broken_rule(:unknown_join_type, permission_set: @set, resource: @resource)

        found = finding(:unknown_rule_operators)

        assert_equal :high, found.severity
        assert_equal 'rule', found.check
        assert_match 'matches nothing', found.detail
        assert_equal ['Sales › Customer.id regex "1": Rule unknown_operator · 1 person',
                      'Sales › Customer.supplier.id equal "1": Rule unknown_join_type (join type "inner") · 1 person'], found.items
        assert_nil finding(:missing_rule_columns)
        assert_nil finding(:unusable_rule_values)
      end

      test 'a qualifier naming no table is a missing column finding; one naming a real table of another model is info' do
        broken_rule(:unknown_table, permission_set: @set, resource: @resource)
        foreign = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Foreign', field_name: 'name',
                                             field_value: 'x', include_nulls: false)
        foreign.update_columns(field_name: 'suppliers.name')

        assert_equal ['Sales › Customer.nosuch.name equal "1": Rule unknown_table · 1 person'], finding(:missing_rule_columns).items
        assert_equal :high, finding(:missing_rule_columns).severity

        info = finding(:foreign_table_names)

        assert_equal :info, info.severity
        assert_match 'field_accessor_path', info.detail
        assert_equal ['Sales › Customer.suppliers.name equal "x": Foreign · 1 person'], info.items
        assert_nil finding(:unusable_rule_values)
      end

      test 'each kind lands in exactly one finding' do
        resources = { 'Customer' => @resource }
        rules = FIXTURES.each_key.to_h do |kind|
          name = fixture_model_name(kind)
          resource = resources[name] ||= create_resource(permission_set: @set, name: name, read_access: true)
          [kind, broken_rule(kind, permission_set: @set, resource: resource)]
        end
        report = audit

        rules.each do |kind, rule|
          named = report.findings.select { |item| item.items.any? { |line| line.include?(rule.name) } }.map(&:code)

          assert_equal 1, named.size, "#{kind}: #{named.inspect}"
        end
        assert_equal %i[missing_rule_columns unknown_rule_operators unusable_rule_values].sort,
                     report.findings.map(&:code).intersection(%i[missing_rule_columns unknown_rule_operators unusable_rule_values]).sort
      end

      test 'a rule nobody holds, or not in effect, weighs less or is left out' do
        PermissionForge::PermissionSetUser.where(permission_set: @set).find_each(&:destroy!)
        broken_rule(:unknown_operator, permission_set: @set, resource: @resource)

        assert_equal :medium, finding(:unknown_rule_operators).severity

        @set.update!(is_active: false)

        assert_nil finding(:unknown_rule_operators)
      end
    end
  end
end
