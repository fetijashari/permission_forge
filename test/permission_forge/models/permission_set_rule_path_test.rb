# frozen_string_literal: true

require 'test_helper'
require_relative '../rule_path_models'

module PermissionForge
  # A join rule's field_accessor_path has to be a path ActiveRecord can join.
  # One naming no association (`ownr` for `owner`) was saved (201 through the
  # API), and then every find_by / permission_scoped of its holders raised
  # ActiveRecord::ConfigurationError — a 500 in the host app. It is refused
  # when it is written, and one written before (or past the model) denies.
  class PermissionSetRulePathTest < ActiveSupport::TestCase
    NotAuthorizedError = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

    setup do
      @permission_set = create_permission_set(name: 'Sales')
      @resource = create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
    end

    teardown do
      Current.user = nil
    end

    # --- refused at save ---

    test 'a path naming no association is refused on field_accessor_path, naming the segment and the model' do
      rule = build_rule(field_accessor_path: 'ownr')

      assert_not rule.valid?
      assert_equal ['names ownr, which is not an association of Customer'], rule.errors[:field_accessor_path]
      assert_equal ['Field accessor path names ownr, which is not an association of Customer'], rule.errors.full_messages

      deeper = build_rule(field_accessor_path: 'supplier.ownr', field_name: 'owner_id')

      assert_not deeper.valid?
      assert_equal ['names ownr, which is not an association of Supplier'], deeper.errors[:field_accessor_path]
    end

    test 'the messages are translated' do
      {
        sq: ['përmend ownr, që nuk është lidhje e Customer', 'përmend subject, një lidhje polimorfike e PfRulePathRecord',
             'përmend phantom, një lidhje e PfRulePathRecord klasa e së cilës nuk mund të ngarkohet'],
        mk: ['го именува ownr, што не е асоцијација на Customer', 'го именува subject, полиморфна асоцијација на PfRulePathRecord',
             'го именува phantom, асоцијација на PfRulePathRecord чија класа не може да се вчита']
      }.each do |locale, (unknown, polymorphic, not_loadable)|
        I18n.with_locale(locale) do
          assert_equal [unknown], build_rule(field_accessor_path: 'ownr').tap(&:valid?).errors[:field_accessor_path], locale
          message = path_rule('subject').tap(&:valid?).errors[:field_accessor_path].first

          assert message.start_with?(polymorphic), "#{locale}: #{message}"
          assert_equal [not_loadable], path_rule('phantom').tap(&:valid?).errors[:field_accessor_path], locale
        end
      end
    end

    # The message says why (review round 5): not "(polymorphic, or its class
    # cannot be loaded)" for every association a join cannot be built through.
    test 'a path ActiveRecord cannot join is refused with its cause, and one it joins is accepted' do
      PfRulePathRecord::NOT_JOINED.each_key do |path|
        rule = path_rule(path)
        followed = Operators::RulePath.follow(PfRulePathRecord, path.split('.'))
        expected = format(Operators::RULE_PROBLEM_MESSAGES.fetch(Operators::RuleProblem.for(rule).key),
                          association: followed.segment, model: followed.owner.name)

        assert_not rule.valid?, path
        assert_equal [expected], rule.errors[:field_accessor_path], path
      end
      PfRulePathRecord::JOINED.each do |path|
        rule = path_rule(path)

        assert rule.valid?, "#{path}: #{rule.errors.full_messages}"
      end
      assert build_rule(field_accessor_path: 'supplier.owner', field_name: 'deactivated', join_type: 'left_joins').valid?
    end

    test 'each cause has its own message' do
      {
        'subject' => 'names subject, a polymorphic association of PfRulePathRecord: a rule cannot join it',
        'phantom' => 'names phantom, an association of PfRulePathRecord whose class cannot be loaded',
        'namesake_children' => 'names namesake_children, an association of PfRulePathRecord whose scope (or one along ' \
                               'its :through) takes the record: a rule cannot join it',
        'ghosts' => 'names ghosts, an association of PfRulePathRecord whose :through, :source or inverse_of names an ' \
                    'association that is not there',
        'parent..owner' => 'has an empty association name (two dots in a row, or a dot at the start)'
      }.each do |path, message|
        assert_equal [message], path_rule(path).tap(&:valid?).errors[:field_accessor_path], path
      end
    end

    # A model file that raises as it loads: the admin and the audit describe
    # the rule ("cannot tell"), they never fail on it; the applier still
    # never answers for it — a RuntimeError makes the path broken (the rule
    # denies), a ScriptError propagates as it did.
    test 'a model file that raises while it loads is "cannot tell" for the admin, never an answer from the applier' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'boom.rb'), "raise 'boom while loading'\n")
        File.write(File.join(dir, 'syntax.rb'), "class PfRulePathSyntaxTarget < ApplicationRecord\n  def x(\nend\n")
        Object.autoload(:PfRulePathBoomTarget, File.join(dir, 'boom.rb'))
        Object.autoload(:PfRulePathSyntaxTarget, File.join(dir, 'syntax.rb'))
        Object.const_set(:PfRulePathLoadFailure, Class.new(ApplicationRecord) do
          self.table_name = 'pf_rule_path_records'
          belongs_to :boom, class_name: 'PfRulePathBoomTarget', optional: true
          belongs_to :syntax, class_name: 'PfRulePathSyntaxTarget', optional: true
        end)
        resource = create_resource(permission_set: @permission_set, name: 'PfRulePathLoadFailure', read_access: true)

        boom = build_rule(resource: resource, field_accessor_path: 'boom')
        assert_equal :unjoinable_class_not_loadable, Operators::RuleProblem.for(boom)&.key
        syntax = build_rule(resource: resource, field_accessor_path: 'syntax')
        assert_nil Operators::RuleProblem.for(syntax)
        assert_nil Operators::RuleColumn.for_rule(syntax)
        assert syntax.valid?, 'nothing can be told: left to the query'

        rule = { name: 'r', operator: 'equal', field_name: 'id', field_value: '1', join_type: 'joins', failure_message: 'no' }
        query, = Services::PermissionRuleApplier.call(model_class: PfRulePathLoadFailure, rules: [rule.merge(field_accessor_path: 'boom')],
                                                      args: [{ id: 1 }], current_user: nil)
        assert_empty query.to_a
        assert_raises(SyntaxError) do
          Services::PermissionRuleApplier.call(model_class: PfRulePathLoadFailure, rules: [rule.merge(field_accessor_path: 'syntax')],
                                               args: [{ id: 1 }], current_user: nil)
        end
      ensure
        %i[PfRulePathLoadFailure PfRulePathBoomTarget PfRulePathSyntaxTarget].each do |name|
          Object.send(:remove_const, name) if Object.const_defined?(name, false) || Object.autoload?(name)
        end
      end
    end

    test 'a filter rule is not checked for its path: it is never joined' do
      assert build_rule(field_accessor_path: 'ownr', join_type: nil, field_name: 'supplier_id').valid?
    end

    test 'a model that cannot be loaded is skipped, not an error' do
      @resource.update_columns(name: 'FreightCost')

      assert build_rule(field_accessor_path: 'ownr').valid?
    end

    test 'an existing row is checked only when its path, join type or model changes' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource, field_name: 'owner_id',
                                        join_type: 'joins', field_accessor_path: 'supplier')
      rule.update_columns(field_accessor_path: 'ownr')

      assert rule.reload.update(field_value: '5', name: 'Renamed', is_active: false), rule.errors.full_messages.inspect
      assert rule.update(field_name: 'id'), 'a rename of the column is no change of path'
      assert_not rule.update(field_accessor_path: 'suppler')
      assert_equal ['names suppler, which is not an association of Customer'], rule.errors[:field_accessor_path]

      rule.reload
      assert_not rule.update(join_type: 'left_joins')
      assert rule.reload.update(join_type: nil, field_name: 'supplier_id'), 'a filter rule: the path is not joined'
    end

    # --- a rule saved before: it denies, it does not raise ---

    test 'a holder of a rule whose path cannot be followed is denied every record, never a 500' do
      user = create_user
      create_permission_set_user(user: user, permission_set: @permission_set)
      customer = create_customer(supplier: create_supplier(owner_id: user.id))
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Owner',
                                        failure_message: 'Not yours', field_name: 'owner_id', join_type: 'joins',
                                        field_accessor_path: 'supplier', include_nulls: false)
      Current.user = user

      assert_equal [customer], Customer.permission_scoped.to_a

      rule.update_columns(field_accessor_path: 'ownr')
      user.invalidate_permissions

      assert_empty Customer.permission_scoped
      error = assert_raises(NotAuthorizedError) { Customer.find_by(uuid: customer.uuid) }
      assert_equal ['Not yours'], error.failure_messages
      assert_raises(NotAuthorizedError) { Customer.find_by!(uuid: customer.uuid) }
      assert_nil Customer.find_by(uuid: 'missing'), 'a record that does not exist is still not found'
    end

    test 'cloning a set copies a rule whose path cannot be followed as it is' do
      rule = create_permission_set_rule(permission_set: @permission_set, resource: @resource, name: 'Bad', field_name: 'owner_id',
                                        join_type: 'joins', field_accessor_path: 'supplier')
      rule.update_columns(field_accessor_path: 'ownr')

      copy = Services::PermissionSetCloner.call(permission_set: @permission_set.reload, attrs: { name: 'Sales copy' })

      assert_equal [%w[Bad ownr]], copy.resources.first.permission_set_rules.pluck(:name, :field_accessor_path)
    end

    private

    def build_rule(**attrs)
      PermissionForge::PermissionSetRule.new({
        uuid: SecureRandom.uuid, name: 'Rule', field_name: 'id', field_value: '5', operator: 'equal',
        join_type: 'joins', permission_set: @permission_set, resource: @resource
      }.merge(attrs))
    end

    def path_rule(path)
      @path_resource ||= create_resource(permission_set: @permission_set, name: 'PfRulePathRecord', read_access: true)
      build_rule(resource: @path_resource, field_accessor_path: path)
    end
  end
end
