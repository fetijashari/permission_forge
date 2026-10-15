require 'test_helper'

module PermissionForge
  class PermissionSetRuleValidationTest < ActiveSupport::TestCase
    setup do
      @permission_set = create_permission_set
      @resource = create_resource(permission_set: @permission_set, name: 'Customer')
    end

    # --- Operator validation ---

    PermissionForge::Operators::Constants::OPERATORS.each do |op|
      test "valid rule with operator #{op}" do
        attrs = valid_rule_attrs(operator: op)
        # is_null and is_not_null don't need field_value
        if op.in?(%w[is_null is_not_null])
          attrs[:field_value] = nil
        elsif op == 'between'
          attrs[:field_value] = '1,10'
        elsif op.in?(%w[in not_in])
          attrs[:field_value] = 'a,b'
        end
        rule = PermissionForge::PermissionSetRule.new(attrs)
        assert rule.valid?, "Expected rule with operator '#{op}' to be valid, errors: #{rule.errors.full_messages}"
      end
    end

    test 'invalid operator string is rejected' do
      rule = build_rule(operator: 'invalid_op')
      assert_not rule.valid?
      assert_includes rule.errors[:operator], I18n.t('permission_forge.validations.permission_set_rule.invalid_operator',
                                                     default: 'is not a valid operator')
    end

    test 'blank operator is rejected' do
      rule = build_rule(operator: '')
      assert_not rule.valid?
      assert rule.errors[:operator].any?
    end

    # --- field_value presence ---

    test 'field_value blank for equal operator is rejected' do
      rule = build_rule(operator: 'equal', field_value: '')
      assert_not rule.valid?
      assert rule.errors[:field_value].any?
    end

    test 'field_value blank for is_null is allowed' do
      rule = build_rule(operator: 'is_null', field_value: nil)
      assert rule.valid?, "Expected is_null rule without field_value to be valid, errors: #{rule.errors.full_messages}"
    end

    test 'field_value blank for is_not_null is allowed' do
      rule = build_rule(operator: 'is_not_null', field_value: nil)
      assert rule.valid?, "Expected is_not_null rule without field_value to be valid, errors: #{rule.errors.full_messages}"
    end

    # --- between operator ---

    test 'between with exactly 2 comma-separated values is valid' do
      rule = build_rule(operator: 'between', field_value: '1,10')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'between with 1 value is invalid' do
      rule = build_rule(operator: 'between', field_value: '1')
      assert_not rule.valid?
      assert(rule.errors[:field_value].any? { |e| e.include?('2 comma-separated') })
    end

    test 'between with 3 values is invalid' do
      rule = build_rule(operator: 'between', field_value: '1,5,10')
      assert_not rule.valid?
      assert(rule.errors[:field_value].any? { |e| e.include?('2 comma-separated') })
    end

    test 'between with empty string is invalid' do
      rule = build_rule(operator: 'between', field_value: '')
      assert_not rule.valid?
      assert rule.errors[:field_value].any?
    end

    # --- in / not_in operator ---

    test 'in with 1 value is valid' do
      rule = build_rule(operator: 'in', field_value: 'active')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'in with 3 values is valid' do
      rule = build_rule(operator: 'in', field_value: 'a,b,c')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'in with blank value is invalid' do
      rule = build_rule(operator: 'in', field_value: ' , , ')
      assert_not rule.valid?
      assert rule.errors[:field_value].any?
    end

    test 'not_in with 1 value is valid' do
      rule = build_rule(operator: 'not_in', field_value: 'inactive')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'not_in with blank value is invalid' do
      rule = build_rule(operator: 'not_in', field_value: ' , ')
      assert_not rule.valid?
      assert rule.errors[:field_value].any?
    end

    # --- join_type validation ---

    test 'join_type nil is valid' do
      rule = build_rule(join_type: nil)
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'join_type joins is valid' do
      rule = build_rule(join_type: 'joins')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'join_type left_joins is valid' do
      rule = build_rule(join_type: 'left_joins')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'join_type left_outer_joins is valid' do
      rule = build_rule(join_type: 'left_outer_joins')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'join_type inner_joins is invalid' do
      rule = build_rule(join_type: 'inner_joins')
      assert_not rule.valid?
      assert rule.errors[:join_type].any?
    end

    test 'join_type empty string is invalid' do
      rule = build_rule(join_type: '')
      assert_not rule.valid?
      assert rule.errors[:join_type].any?
    end

    # --- field_name validation ---

    test 'field_name domain is valid' do
      rule = build_rule(field_name: 'domain')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'field_name user.email is valid' do
      rule = build_rule(field_name: 'user.email')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'field_name created_at is valid' do
      rule = build_rule(field_name: 'created_at')
      assert rule.valid?, "Errors: #{rule.errors.full_messages}"
    end

    test 'field_name blank is invalid' do
      rule = build_rule(field_name: '')
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name nil is invalid' do
      rule = build_rule(field_name: nil)
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name with SQL injection attempt is invalid' do
      rule = build_rule(field_name: 'Robert"; DROP TABLE users;--')
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name starting with number is invalid' do
      rule = build_rule(field_name: '123abc')
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name with spaces is invalid' do
      rule = build_rule(field_name: 'field name')
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name with hyphens is invalid' do
      rule = build_rule(field_name: 'field-name')
      assert_not rule.valid?
      assert rule.errors[:field_name].any?
    end

    test 'field_name with an empty segment is invalid for a new rule' do
      ['flag.', 'customers.flag.', 'customers..flag', 'a.b..c', 'flag..'].each do |name|
        rule = build_rule(field_name: name)

        assert_not rule.valid?, name
        assert_equal 1, rule.errors[:field_name].size, name
      end
      assert_equal 1, build_rule(field_name: '.flag').tap(&:valid?).errors[:field_name].size
    end

    test 'field_name with a schema or database before the table is valid' do
      %w[customers.supplier_id public.customers.supplier_id mydb.customers.Supplier_Id a.b.c.d].each do |name|
        assert build_rule(field_name: name).valid?, name
      end
    end

    test 'a rule that already carries such a name stays editable, but cannot be renamed to another' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      rule.update_columns(field_name: 'supplier_id.')
      rule.reload

      assert rule.update(name: 'Renamed', failure_message: 'Other', is_active: false, field_value: '7')
      assert_equal 'supplier_id.', rule.reload.field_name
      assert_not rule.update(field_name: 'domain.')
      assert rule.errors[:field_name].any?
      assert rule.update(field_name: 'customers.supplier_id')
    end

    # --- combination errors ---

    test 'invalid operator AND invalid join_type produces both errors' do
      rule = build_rule(operator: 'bogus', join_type: 'inner_joins')
      assert_not rule.valid?
      assert rule.errors[:operator].any?
      assert rule.errors[:join_type].any?
    end

    # --- no regressions ---

    test 'a null check saves with no field_value (the column is NOT NULL): it is stored as empty' do
      %w[is_null is_not_null].each do |op|
        rule = build_rule(operator: op, field_value: nil)
        assert rule.save, rule.errors.full_messages.to_sentence
        assert_equal '', rule.reload.field_value
      end
    end

    test 'the operators that take no value come from the validations registry' do
      assert_equal %w[is_null is_not_null].sort, PermissionForge::Operators::Validations::VALUELESS.sort
      assert PermissionForge::Operators::Validations.valueless?('is_null')
      assert_not PermissionForge::Operators::Validations.valueless?('equal')
    end

    test 'an operator that needs a value still refuses nil' do
      rule = build_rule(operator: 'equal', field_value: nil)
      assert_not rule.valid?
      assert rule.errors[:field_value].any?
    end

    test 'existing valid rules from test helper still pass' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource)
      assert rule.persisted?
      assert rule.valid?
    end

    private

    def valid_rule_attrs(overrides = {})
      {
        uuid: SecureRandom.uuid,
        name: 'Test Rule',
        failure_message: 'Access denied',
        field_name: 'supplier_id',
        field_value: 'current_user',
        operator: 'equal',
        include_nulls: true,
        is_active: true,
        is_editable: true,
        permission_set: @permission_set,
        resource: @resource
      }.merge(overrides)
    end

    def build_rule(overrides = {})
      PermissionForge::PermissionSetRule.new(valid_rule_attrs(overrides))
    end
  end
end
