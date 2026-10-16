# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Operators
    # A qualified field_name whose table is none of the rule's used to reach
    # SQL as written ("nosuch"."name") and raise ActiveRecord::StatementInvalid
    # for every holder. It is now one of three things: a name the rule's own
    # query gives a table (UNKNOWN: an alias a join gives, left to the
    # database), a real table that is none of the rule's (FOREIGN: a filter
    # rule matches nothing; a join rule's query must join it itself), or no
    # table at all (UNRESOLVABLE: matches nothing).
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
        %w[nosuch.name customer.name pf_no_such.name].each do |field_name|
          target = RuleColumn.find(field_name, [Customer])

          assert_predicate target, :unresolvable?, field_name
          assert_not target.missing?, field_name
          assert_not target.malformed?, field_name
          assert_nil target.model, field_name
        end
      end

      test 'a qualifier naming a real table that is none of the rule\'s is a foreign table' do
        target = RuleColumn.find('suppliers.name', [Customer])

        assert_same RuleColumn::FOREIGN, target
        assert_predicate target, :foreign?
        assert_not target.unresolvable?
        assert_same RuleColumn::FOREIGN, RuleColumn.find('suppliers.name', [Customer], joined: %w[customers])
      end

      # Review R1 #1: a name the joined query mentions (a column of its ON
      # clause) is no name it gives a table. Only the FROM and JOIN names count.
      test 'with a path, a qualifier is an alias only when the joined query gives that name to a table' do
        assert_same RuleColumn::UNKNOWN, RuleColumn.find('parents_customers.name', [Customer, Supplier],
                                                         joined: %w[customers suppliers parents_customers])
        assert_predicate RuleColumn.find('supplier_id.id', [Customer, Supplier], joined: %w[customers suppliers]), :unresolvable?
        assert_predicate RuleColumn.find('parents_customers.name', [Customer, Supplier], joined: %w[customers suppliers]),
                         :unresolvable?
      end

      test 'source_names are the table names and aliases of the FROM and JOINs, not the names in their conditions' do
        assert_equal %w[customers suppliers], RuleColumn.source_names(Customer.joins(:supplier)).sort
        assert_equal %w[customers], RuleColumn.source_names(Customer.where(supplier_id: 1))

        require_relative '../rule_path_models'
        assert_includes RuleColumn.source_names(PfRulePathRecord.joins(:parent)), 'parents_pf_rule_path_records'
        string_join = Customer.joins('INNER JOIN suppliers AS vendors ON vendors.id = customers.supplier_id')

        assert_equal %w[customers vendors], RuleColumn.source_names(string_join).sort
      end

      test 'a name that is not a name is malformed, whatever it is qualified with' do
        ['a..b', '.name', 'name.', 'nosuch..name', "na\nme", "na\0me", "customers.na\tme", "name\r", ''].each do |field_name|
          assert_not RuleColumn.name?(field_name), field_name.inspect
          assert_predicate RuleColumn.find(field_name, [Customer]), :malformed?, field_name.inspect
        end
        ['name', 'customers.name', 'Name', 'na me', 'nämé', 'name-x'].each do |field_name|
          assert RuleColumn.name?(field_name), field_name.inspect
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

        assert_same RuleColumn::FOREIGN, RuleColumn.for_rule(rule.reload)

        rule.update_columns(field_name: 'nosuch.name', join_type: 'joins', field_accessor_path: 'supplier')

        assert_predicate RuleColumn.for_rule(rule.reload), :unresolvable?, 'a join rule: no name its join gives'

        rule.update_columns(field_name: 'supplier_id.id')

        assert_predicate RuleColumn.for_rule(rule.reload), :unresolvable?, 'a column of the ON clause is no table'

        rule.update_columns(field_name: 'users.id')

        assert_same RuleColumn::FOREIGN, RuleColumn.for_rule(rule.reload), 'a join rule: a table its query may join itself'
      end

      test 'a join rule qualified with a stray name is named by RuleProblem and refused on save' do
        set = create_permission_set
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        rule = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'owner_id', field_value: '1',
                                          join_type: 'joins', field_accessor_path: 'supplier')
        rule.update_columns(field_name: 'supplier_id.id')

        assert_equal :unknown_table, RuleProblem.for(rule.reload)&.kind
        assert rule.valid?, 'stored: editable in its other attributes'

        fresh = rule.dup
        fresh.uuid = SecureRandom.uuid
        fresh.field_name = 'supplier_id.owner_id'

        assert_not fresh.valid?
        assert_includes fresh.errors[:field_name], RuleProblem.for(fresh).validation_message
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
