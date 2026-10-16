# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'

module PermissionForge
  # Field test round 7 (D#22): a LIKE operator (contains, not_contains,
  # starts_with, ends_with) on a column no pattern can be matched against
  # was refused as "is not a value … can hold" on field_value — but the value
  # was fine, the operator was not. It has its own reason now
  # (Operators::ValueTyping.problem => :pattern_on_non_text, the RuleProblem
  # kind of that name), refused on `operator` with a sentence naming the
  # column's type. What such a column is depends on the database
  # (ValueCasters.pattern?): a json column on every one, an integer, date or
  # boolean column on PostgreSQL. ValueTyping still answers UNUSABLE: the
  # rule matches nothing.
  class PermissionSetRulePatternOperatorTest < ActiveSupport::TestCase
    setup do
      @set = create_permission_set(name: 'Records')
      @resource = create_resource(permission_set: @set, name: 'PfRulePathRecord', read_access: true)
    end

    def new_rule(**attrs)
      PermissionSetRule.new({ uuid: SecureRandom.uuid, name: 'Pattern', failure_message: 'No', field_name: 'details',
                              field_value: 'a', operator: 'contains', include_nulls: false, permission_set: @set,
                              resource: @resource }.merge(attrs))
    end

    def message(type)
      I18n.t('permission_forge.validations.permission_set_rule.pattern_on_non_text', model: 'PfRulePathRecord', name: 'details',
                                                                                   type: type)
    end

    test 'a LIKE operator on a column no pattern matches is refused on operator, naming the column type' do
      type = PfRulePathRecord.columns_hash['details'].sql_type

      %w[contains not_contains starts_with ends_with].each do |operator|
        rule = new_rule(operator: operator)

        assert_not rule.valid?, operator
        assert_includes rule.errors[:operator], message(type), operator
        assert_empty rule.errors[:field_value], "#{operator}: the value is not what is wrong"
      end
      assert_includes message(type), type
    end

    test 'the reason is its own: ValueTyping.problem tells it from a value the column cannot hold' do
      target = Operators::RuleColumn.find('details', [PfRulePathRecord])
      label = Operators::RuleColumn.find('label', [PfRulePathRecord])

      assert_equal :pattern_on_non_text, Operators::ValueTyping.problem('contains', 'a', target)
      assert_equal :unusable_value, Operators::ValueTyping.problem('equal', 'a', target), 'json takes no value at all'
      assert_nil Operators::ValueTyping.problem('contains', 'a', label)
      assert_nil Operators::ValueTyping.problem('is_null', '', target)
      assert Operators::ValueTyping.call('contains', 'a', target).equal?(Operators::ValueTyping::UNUSABLE), 'still matches nothing'
    end

    test 'the message exists in every locale and names the type' do
      %w[en sq mk].each do |locale|
        text = I18n.t('permission_forge.validations.permission_set_rule.pattern_on_non_text', locale: locale, model: 'M',
                                                                                             name: 'n', type: 'json', default: nil)

        assert text.present?, locale
        assert_includes text, 'json', locale
      end
    end

    test 'a stored one stays editable in its other attributes and is refused again when its operator or value changes' do
      rule = create_permission_set_rule(permission_set: @set, resource: @resource, field_name: 'label', field_value: 'a')
      rule.update_columns(field_name: 'details', operator: 'contains')
      rule.reload

      assert_equal :pattern_on_non_text, Operators::RuleProblem.for(rule)&.kind
      assert rule.update(name: 'Renamed'), rule.errors.full_messages.inspect
      assert_not rule.update(operator: 'starts_with')
      assert rule.errors[:operator].any?
    end
  end
end
