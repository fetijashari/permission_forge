# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Services
    # The applier never raises on a stored rule: a value of the rule tables
    # it cannot interpret matches nothing (every holder is denied every
    # record), never a 500 for every holder. Before: an unknown operator
    # raised ArgumentError, an unknown join type ConfigurationError, and a
    # qualifier naming no table reached SQL as written.
    class PermissionRuleApplierTest < ActiveSupport::TestCase
      NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @user = create_user
        @supplier = create_supplier(name: 'Acme', owner_id: @user.id)
        @mine = create_customer(name: 'mine', supplier: @supplier)
        @theirs = create_customer(name: 'theirs')
      end

      teardown do
        Current.user = nil
        PermissionForge.configuration.auto_query_scoping = :off
      end

      test 'an operator this version does not know matches nothing, under any join type' do
        [nil, 'joins'].each do |join_type|
          relation = scoped(rule(operator: 'regex', field_value: 'm.*', join_type: join_type,
                                 field_accessor_path: (join_type ? 'supplier' : nil)))

          assert_empty relation.to_a, join_type.inspect
        end
        assert_equal [@mine], scoped(rule(operator: 'equal', field_value: 'mine')).to_a, 'a known operator still filters'
      end

      test 'a join type this version does not know matches nothing and never reaches the relation' do
        %w[inner send public_send delete_all destroy_all unscope unscoped none reorder extending instance_eval JOINS].each do |join_type|
          ['delete_all', 'supplier', 'where', nil].each do |path|
            assert_empty scoped(rule(join_type: join_type, field_accessor_path: path)).to_a, "#{join_type} #{path.inspect}"
          end
        end
        assert_equal 2, Customer.where(id: [@mine.id, @theirs.id]).count
      end

      test 'a join type that is not one cannot drop the rules applied before it' do
        own = rule(field_value: 'mine')

        assert_empty scoped(own, rule(join_type: 'unscope', field_accessor_path: 'where')).to_a
        assert_equal [@mine], scoped(own).where(id: [@mine.id, @theirs.id]).to_a
      end

      test 'a qualifier naming no table, on a rule that joins nothing, matches nothing' do
        %w[nosuch.name customer.name].each do |field_name|
          assert_empty scoped(rule(field_name: field_name, field_value: 'mine')).to_a, field_name
        end
      end

      test 'a qualifier naming a table along the path is typed and compared' do
        relation = scoped(rule(join_type: 'joins', field_accessor_path: 'supplier', field_name: 'suppliers.name', field_value: 'Acme'))

        assert_equal [@mine], relation.to_a
      end

      # A join rule's qualifier that is none of the rule's tables: the alias
      # ActiveRecord gives a self-join is compared; a table the joined query
      # does not contain (no such table, or a real one it does not join)
      # matches nothing instead of raising for every holder.
      test 'a join rule qualifier the joined query does not name matches nothing; a self-join alias is compared' do
        require_relative '../rule_path_models'
        parent = PfRulePathRecord.create!(label: 'top')
        child = PfRulePathRecord.create!(label: 'kid', parent: parent)
        PfRulePathRecord.create!(label: 'orphan')
        on_parent = lambda do |field_name|
          PermissionRuleApplier.scope(model_class: PfRulePathRecord, current_user: @user,
                                      operator_registry: PermissionForge::Operators::Registry,
                                      rules: [rule(join_type: 'joins', field_accessor_path: 'parent', field_name: field_name,
                                                   field_value: 'top')])
        end

        assert_equal [child], on_parent.call('parents_pf_rule_path_records.label').to_a
        %w[nosuch.label customers.name].each do |field_name|
          assert_empty on_parent.call(field_name).to_a, field_name
        end
      end

      test 'the holder of such rules is denied every record, in every read path, never a 500' do
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        stored = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'mine')
        Current.user = @user

        { { operator: 'regex' } => 'operator', { join_type: 'inner', field_accessor_path: 'supplier' } => 'join type',
          { field_name: 'nosuch.name' } => 'table' }.each do |attrs, what|
          stored.update_columns({ operator: 'equal', join_type: nil, field_accessor_path: nil, field_name: 'name' }.merge(attrs))
          @user.invalidate_permissions

          assert_empty Customer.permission_scoped.to_a, what
          assert_raises(NotAuthorizedError, what) { Customer.find_by(id: @mine.id) }
          assert_raises(NotAuthorizedError, what) { Customer.find_by!(id: @mine.id) }
          # The default scope applies filter rules only (a join rule is "unenforced" there, as documented).
          next if stored.join_rule?

          PermissionForge.configuration.auto_query_scoping = :filter_only

          assert_equal 0, Customer.count, "#{what}: count under :filter_only"
          assert_empty Customer.all.to_a, "#{what}: all under :filter_only"
          assert_not Customer.where(nil).exists?, "#{what}: exists? under :filter_only"
          PermissionForge.configuration.auto_query_scoping = :off
        end
        assert Customer.unscoped.exists?(@mine.id)
      end

      # A NUL byte in a value is quoted into the statement, which the
      # database reads cut short (ActiveRecord::StatementInvalid for every
      # holder); a control character in a field name is no name. Both match
      # nothing, under a built-in operator and a custom one alike.
      test 'a value with a NUL byte, or a field name with a control character, matches nothing' do
        echo = { 'echo' => ->(query, col, _rule, value) { query.where("#{col} = ?", value) } }.merge(
          'equal' => PermissionForge::Operators::Registry.fetch('equal')
        )
        values = { 'equal' => "mi\0ne", 'in' => "mine,x\0y", 'between' => "a\0,z", 'contains' => "i\0n", 'echo' => "mi\0ne" }

        values.each do |operator, value|
          relation = scoped(rule(operator: operator, field_value: value), registry: PermissionForge::Operators::Registry.strategies.merge(echo))

          assert_empty relation.to_a, "#{operator} #{value.inspect}"
        end
        ["na\nme", "na\0me", "customers.na\tme"].each do |field_name|
          %w[equal echo].each do |operator|
            relation = scoped(rule(field_name: field_name, operator: operator, field_value: 'mine'),
                              registry: PermissionForge::Operators::Registry.strategies.merge(echo))

            assert_empty relation.to_a, "#{field_name.inspect} #{operator}"
          end
        end
        # A name with a space is a name (no such column: none under a built-in operator; a custom operator's strategy decides).
        assert_empty scoped(rule(field_name: 'na me', field_value: 'mine')).to_a
        assert_equal [@mine], scoped(rule(operator: 'echo', field_value: 'mine'),
                                     registry: PermissionForge::Operators::Registry.strategies.merge(echo)).to_a
      end

      # Review R1 #1: the qualifier was looked for in the joined query's SQL
      # text, where a column of the JOIN's ON clause ("customers"."supplier_id")
      # passed for a table: "supplier_id"."id" reached the database and raised
      # for every holder. A qualifier is now one of the names the query's
      # FROM and JOINs give (the table aliases ActiveRecord assigns).
      test 'a join rule qualified with a name the ON clause mentions, which is no table or alias, matches nothing' do
        %w[supplier_id.id customers.supplier_id.id supplier.id id.id].each do |field_name|
          relation = scoped(rule(join_type: 'joins', field_accessor_path: 'supplier', field_name: field_name, field_value: '1'))

          assert_empty relation.to_a, field_name
        end
        assert_equal [@mine], scoped(rule(join_type: 'joins', field_accessor_path: 'supplier', field_name: 'suppliers.id',
                                          field_value: @supplier.id.to_s)).to_a, 'a table the join names is compared'
      end

      # Review R1 #2: a filter rule compares the model's own table. One
      # qualified with another model's table reached SQL as written and
      # raised in every query of its holders (the default scope included).
      test 'a filter rule qualified with a table of another model matches nothing in every gem-built query' do
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        stored = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'name', field_value: 'Acme')
        stored.update_columns(field_name: 'suppliers.name')
        Current.user = @user

        assert_empty scoped(rule(field_name: 'suppliers.name', field_value: 'Acme')).to_a
        assert_empty Customer.permission_scoped.to_a
        assert_raises(NotAuthorizedError) { Customer.find_by(id: @mine.id) }
        assert_raises(NotAuthorizedError) { Customer.find_by!(id: @mine.id) }
        PermissionForge.configuration.auto_query_scoping = :filter_only

        assert_equal 0, Customer.count
        assert_not Customer.where(nil).exists?
        assert_empty Customer.joins(:supplier).to_a, 'also where the host query joins that table'
        PermissionForge.configuration.auto_query_scoping = :off

        assert_equal [@mine], scoped(rule(field_name: 'customers.name', field_value: 'mine')).to_a, 'its own table is compared'
      end

      test 'a registry injected as a Hash is asked the same way' do
        registry = { 'equal' => PermissionForge::Operators::Registry.fetch('equal') }

        assert_equal [@mine], scoped(rule(field_value: 'mine'), registry: registry).to_a
        assert_empty scoped(rule(operator: 'regex', field_value: 'mine'), registry: registry).to_a
      end

      private

      def rule(**attrs)
        { name: 'Own', failure_message: 'No', field_name: 'name', operator: 'equal', field_value: 'mine',
          include_nulls: false }.merge(attrs)
      end

      def scoped(*rules, registry: PermissionForge::Operators::Registry)
        PermissionRuleApplier.scope(model_class: Customer, rules: rules, current_user: @user, operator_registry: registry)
      end
    end
  end
end
