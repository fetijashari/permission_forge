# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # A rule's join_type picks one of three relation methods and nothing else.
    # The model validates it, but a rule row can be written past the model (the
    # tables are shared with other applications), and it used to be sent to the
    # relation as it was: `send` with a field_accessor_path of `delete_all`
    # emptied the table, `unscope` dropped the rules applied before it.
    class RuleJoinTypeTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @supplier = create_supplier(owner_id: @user.id)
        @mine = create_customer(name: 'mine', supplier: @supplier)
        @theirs = create_customer(name: 'theirs', supplier: create_supplier(owner_id: @user.id + 1))
      end

      # A join type this version does not know matches nothing (every holder
      # is denied every record), never a raise for every holder and never a
      # method called on the relation.
      test 'a join_type that is not one matches nothing and never reaches the relation' do
        %w[send public_send delete_all destroy_all unscope unscoped none reorder extending instance_eval JOINS].each do |join_type|
          ['delete_all', 'supplier', 'where', nil].each do |path|
            assert_empty scoped(owner_rule(join_type: join_type, field_accessor_path: path)).to_a, "#{join_type} #{path.inspect}"
          end
        end

        assert_equal 2, Customer.where(id: [@mine.id, @theirs.id]).count
      end

      test 'a join_type that is not one cannot drop the rules applied before it' do
        own = { name: 'Own', failure_message: 'No', field_name: 'name', operator: 'equal', field_value: 'mine', include_nulls: false }

        assert_empty scoped(own, owner_rule(join_type: 'unscope', field_accessor_path: 'where')).to_a
        assert_equal [@mine], scoped(own).where(id: [@mine.id, @theirs.id]).to_a
      end

      # One reading of "this is a filter rule" everywhere: a row written past
      # the model with a blank join_type must not be a filter to the default
      # scope and an error to the applier.
      test 'a blank join_type is a filter rule to the applier, the default scope and the model alike' do
        own = { name: 'Own', failure_message: 'No', field_name: 'name', operator: 'equal', field_value: 'mine', include_nulls: false }

        [nil, '', ' ', "\t", 'filter', :filter].each do |join_type|
          assert PermissionForge::PermissionSetRule.filter_join_type?(join_type), join_type.inspect
          assert_not PermissionForge::PermissionSetRule.new(join_type: join_type).join_rule?, join_type.inspect
          assert_equal [@mine], scoped(own.merge(join_type: join_type)).where(id: [@mine.id, @theirs.id]).to_a, join_type.inspect
          assert Customer.send(:pf_filter_rule?, own.merge(join_type: join_type)), join_type.inspect
        end

        %w[Filter joins garbage].each do |join_type|
          assert_not PermissionForge::PermissionSetRule.filter_join_type?(join_type), join_type
        end
        assert_not Customer.send(:pf_filter_rule?, own.merge(join_type: 'joins')), 'a join rule is permission_scoped\'s'
        # A join type this version does not know joins nothing and matches
        # nothing: the default scope applies it too (review R1), or it would
        # be wider than find_by and permission_scoped.
        %w[Filter garbage].each do |join_type|
          assert Customer.send(:pf_filter_rule?, own.merge(join_type: join_type)), join_type
        end
      end

      test 'find_by and permission_scoped deny as well, never a 500' do
        set = create_permission_set
        create_permission_set_user(user: @user, permission_set: set)
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        rule = create_permission_set_rule(permission_set: set, resource: resource, field_name: 'owner_id',
                                          join_type: 'joins', field_accessor_path: 'supplier', include_nulls: false)
        rule.update_columns(join_type: 'send', field_accessor_path: 'delete_all')
        @user.invalidate_permissions
        Current.user = @user

        assert_raises(PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError) { Customer.find_by(id: @mine.id) }
        assert_empty Customer.permission_scoped.to_a
        assert Customer.unscoped.exists?(@mine.id)
      ensure
        Current.user = nil
      end

      test 'the three join types join, written as text or as a symbol' do
        ['joins', 'left_joins', 'left_outer_joins', :joins, :left_joins].each do |join_type|
          relation = scoped(owner_rule(join_type: join_type, field_accessor_path: 'supplier'))

          assert_equal [@mine], relation.where(id: [@mine.id, @theirs.id]).to_a, join_type.inspect
        end
      end

      # ActiveRecord would raise for the join when the query runs — a 500 in
      # every find_by / permission_scoped of the rule's holders. The rule
      # matches nothing instead, for a usable value and for an unusable one,
      # under a built-in operator and a custom one (the join is never built).
      test 'an association path that cannot be followed matches nothing' do
        %w[nowhere supplier.nowhere supplier..owner].each do |path|
          [%w[equal 5], %w[equal x], ['is_null', ''], %w[custom_op 5]].each do |operator, value|
            rule = owner_rule(join_type: 'joins', field_accessor_path: path, field_name: 'supplier_id',
                              operator: operator, field_value: value)

            assert_empty scoped(rule).to_a, "#{path} #{operator} #{value}"
          end
        end
        assert_equal [@mine], scoped(owner_rule(join_type: 'joins', field_accessor_path: 'supplier'))
          .where(id: [@mine.id, @theirs.id]).to_a, 'a path that is followed still joins'
      end

      test 'a filter rule has no join, whatever its field_accessor_path says' do
        [nil, '', 'filter', :filter].each do |join_type|
          rule = { name: 'Filter', failure_message: 'No', field_name: 'name', operator: 'equal', field_value: 'mine',
                   include_nulls: false, join_type: join_type, field_accessor_path: 'delete_all' }

          assert_equal [@mine], scoped(rule).where(id: [@mine.id, @theirs.id]).to_a, join_type.inspect
        end
      end

      private

      def owner_rule(**attrs)
        { name: 'Owner', failure_message: 'No', field_name: 'owner_id', operator: 'equal', field_value: 'current_user',
          include_nulls: false }.merge(attrs)
      end

      def scoped(*rules)
        PermissionForge::Services::PermissionRuleApplier.scope(model_class: Customer, rules: rules, current_user: @user)
      end
    end
  end
end
