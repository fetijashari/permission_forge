# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Operators
    # A qualified field_name whose table is none of the rule's used to reach
    # SQL as written ("nosuch"."name") and raise ActiveRecord::StatementInvalid
    # for every holder. It is now one of three things: a table the query may
    # join itself (UNKNOWN, left to the database), no table at all on a rule
    # that joins nothing (UNRESOLVABLE: matches nothing), or — with a path —
    # possibly an alias the join gives a table (UNKNOWN: an alias is no data
    # source, and a self-join is named by one).
    class RuleColumnTest < ActiveSupport::TestCase
      class TablelessRecord < ActiveRecord::Base
        self.table_name = 'pf_rule_column_test_no_such_table'
      end

      class AbstractRecord < ActiveRecord::Base
        self.abstract_class = true
      end

      test 'a column of the rule\'s own table, plain or qualified, is found' do
        assert_equal 'name', RuleColumn.find('name', [Customer]).column.name
        assert_equal 'name', RuleColumn.find('customers.name', [Customer]).column.name
        assert_equal 'name', RuleColumn.find('public.customers.name', [Customer]).column.name
        assert_equal Customer, RuleColumn.find('customers.name', [Customer]).model
      end

      test 'a column of a table along the path is found' do
        assert_equal Supplier, RuleColumn.find('suppliers.owner_id', [Customer, Supplier]).model
        assert_equal Supplier, RuleColumn.find('owner_id', [Customer, Supplier]).model
      end

      test 'a qualifier naming no table, on a rule that joins nothing, is unresolvable' do
        %w[nosuch.name customer.name Customers.name pf_no_such.name].each do |field_name|
          target = RuleColumn.find(field_name, [Customer])

          assert_predicate target, :unresolvable?, field_name
          assert_not target.missing?, field_name
          assert_not target.malformed?, field_name
          assert_nil target.model, field_name
        end
      end

      test 'a qualifier naming a real table that is none of the rule\'s is left to the database' do
        target = RuleColumn.find('suppliers.name', [Customer])

        assert_same RuleColumn::UNKNOWN, target
        assert_not target.unresolvable?
      end

      test 'with a path, a qualifier naming no table may be an alias the join gives: left to the database' do
        target = RuleColumn.find('parents_customers.name', [Customer, Supplier])

        assert_same RuleColumn::UNKNOWN, target
      end

      test 'a name that is not a name is malformed, whatever it is qualified with' do
        %w[a..b .name name. nosuch..name].each do |field_name|
          assert_predicate RuleColumn.find(field_name, [Customer]), :malformed?, field_name
        end
      end

      test 'the states are distinct and frozen' do
        assert_not RuleColumn::UNKNOWN.equal?(RuleColumn::UNRESOLVABLE)
        assert_not RuleColumn::MALFORMED.equal?(RuleColumn::UNRESOLVABLE)
        assert_predicate RuleColumn::UNRESOLVABLE, :frozen?
        assert_not RuleColumn::UNKNOWN.unresolvable?
        assert_not RuleColumn::MALFORMED.unresolvable?
      end

      test 'for_rule finds the column of a filter rule the way the applier does' do
        set = create_permission_set
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        rule = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'x')
        rule.update_columns(field_name: 'nosuch.name')

        assert_predicate RuleColumn.for_rule(rule.reload), :unresolvable?

        rule.update_columns(field_name: 'suppliers.name')

        assert_same RuleColumn::UNKNOWN, RuleColumn.for_rule(rule.reload)

        rule.update_columns(field_name: 'nosuch.name', join_type: 'joins', field_accessor_path: 'supplier')

        assert_same RuleColumn::UNKNOWN, RuleColumn.for_rule(rule.reload), 'a join rule: the name may be an alias'
      end

      test 'rule_model is the one model lookup: a class with a table, not abstract, not a module' do
        set = create_permission_set
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        rule = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'x')

        assert_equal Customer, RuleColumn.rule_model(rule)

        { 'Kernel' => 'a module', 'String' => 'not a model', TablelessRecord.name => 'no table',
          AbstractRecord.name => 'abstract', 'PermissionForge' => 'the gem', 'Nope::Nope' => 'no constant' }.each do |name, why|
          rule.resource.update_columns(name: name)

          assert_nil RuleColumn.rule_model(rule.reload), why
        end
      end
    end
  end
end
