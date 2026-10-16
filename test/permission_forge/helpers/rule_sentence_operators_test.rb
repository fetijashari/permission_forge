# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Round 7 (S6, critique 31): a rule's sentence reads its operator sets from
  # the definitions that decide — Operators::Registry::NULL_INCLUDING (the
  # strategies that add the NULL rows), ValueTyping::SHAPES (a list, a pair)
  # and Validations::VALUELESS — never lists of its own. "The current user"
  # is said only where ValueTyping substitutes the user's id (one value
  # compared); a range's two ends are split as ValueTyping splits them.
  class RuleSentenceOperatorsTest < ActionView::TestCase
    tests PermissionForge::ApplicationHelper

    def rule(operator, value, include_nulls: false)
      PermissionForge::PermissionSetRule.new(operator: operator, field_value: value, field_name: 'name', include_nulls: include_nulls)
    end

    test 'the operators that add the NULL rows are the strategies that do, and the policy reads the same list' do
      relation = Customer.all
      column = "#{Customer.quoted_table_name}.#{Customer.connection.quote_column_name('name')}"
      adding = Operators::Constants::OPERATORS.reject do |operator|
        typed = %i[single pattern].include?(Operators::ValueTyping::SHAPES[operator]) ? 'x' : %w[x y]
        typed = nil if Operators::Validations.valueless?(operator)
        with = Operators::Registry.fetch(operator).call(relation, column, { include_nulls: true, field_value: 'x,y' }, typed).to_sql
        without = Operators::Registry.fetch(operator).call(relation, column, { include_nulls: false, field_value: 'x,y' }, typed).to_sql
        with == without
      end

      assert_equal adding.sort, Operators::Registry::NULL_INCLUDING.sort
      assert_same Operators::Registry::NULL_INCLUDING, Services::RlsOperatorSql::NULL_INCLUDING
      Operators::Constants::OPERATORS.each do |operator|
        assert_equal Operators::Registry::NULL_INCLUDING.include?(operator), pf_rule_nullable?(rule(operator, 'x', include_nulls: true)), operator
      end
    end

    test 'the sentence keeps no operator list of its own' do
      %i[NULLABLE_OPERATORS LIST_OPERATORS NO_VALUE_OPERATORS USER_OPERATORS].each do |name|
        assert_not SentencesHelper.const_defined?(name, false), "SentencesHelper::#{name} re-derives an operator set"
      end
    end

    test '"the current user" is said only where one value is compared' do
      assert_equal t('permission_forge.ui.rules.current_user'), pf_rule_value_text(rule('equal', 'current_user'))
      assert_equal t('permission_forge.ui.rules.current_user'), pf_rule_value_text(rule('not_equal', 'current_user'))
      assert_equal 'current_user', pf_rule_value_text(rule('in', 'current_user')), 'in a list it is the word as written'
      assert_equal 'current_user', pf_rule_value_text(rule('not_in', 'current_user'))
    end

    test 'a list and a range are split as ValueTyping splits them; a valueless operator shows no value' do
      assert_equal 'a, b', pf_rule_value_text(rule('in', 'a,b'))
      assert_equal "a #{t('permission_forge.ui.rules.and')} b", pf_rule_value_text(rule('between', 'a, b'))
      assert_equal Operators::ValueTyping.split('a,b,c').join(" #{t('permission_forge.ui.rules.and')} "),
                   pf_rule_value_text(rule('between', 'a,b,c')), 'three ends read as three, as ValueTyping reads them'
      Operators::Validations::VALUELESS.each { |operator| assert_nil pf_rule_value_token(rule(operator, nil)), operator }
    end
  end
end
