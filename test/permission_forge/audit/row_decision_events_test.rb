# frozen_string_literal: true

require 'test_helper'
require_relative 'runtime_support'

module PermissionForge
  module Audit
    # access.denied and rule.bypassed from find_by / find_by! / permission_scoped,
    # auto-scoping (Level 1), the rule applier and Level 2 detection.
    class RowDecisionEventsTest < ActiveSupport::TestCase
      include RuntimeSupport

      NotAuthorized = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @user = create_user(name: 'Ada Lovelace')
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer')
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers', include_nulls: false)
        @mine = create_customer(supplier_id: @user.id)
        @denied = create_customer(supplier_id: @user.id + 1000)
        Current.user = @user
      end

      teardown do
        PermissionForge.configuration.auto_query_scoping = :off
        Customer.permission_forge_auto_scope = true
      end

      def grant(**flags)
        @resource.update!(**flags)
        @user.reload
      end

      # --- row denial ----------------------------------------------------------------

      test 'a row a rule denies is stored as access.denied with the actor, the user, the model and the id' do
        assert_difference -> { AuditEvent.where(event: 'access.denied').count }, 1 do
          assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied.uuid) }
        end

        event = assert_audit_event('access.denied', record_type: 'Customer', record_id: @denied.id.to_s,
                                                    subject_user_id: @user.id.to_s, actor_type: 'user',
                                                    actor_id: @user.id.to_s, actor_label: 'Ada Lovelace',
                                                    source: 'runtime', category: 'access')
        assert_equal 'rule', event.data['reason']
        assert_equal 'find_by', event.data['via']
        assert_equal 'Customer', event.data['model']
        assert_equal ['[Forbidden by Rule: Own customers] with message: Access denied by test rule'], event.data['messages']
      end

      test 'the error carries the user and the id, and keeps its constant, message and details' do
        error = assert_raises(NotAuthorized) { Customer.find_by(uuid: @denied.uuid) }

        assert_same @user, error.user
        assert_equal @denied.id, error.record_id
        assert_nil error.record, 'the denied row is not handed out with the error'
        assert_equal error.details.join(', '), error.message
        assert_includes error.details.first, 'Own customers'
        assert_equal 'PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError', error.class.name
      end

      test 'the error is built as before by hosts' do
        assert_equal({ message: 'x' }, NotAuthorized.new({ message: 'x' }).details)
        assert_equal({ message: 'x' }, NotAuthorized.new(message: 'x').details)
        assert_equal({}, NotAuthorized.new.details)
        error = NotAuthorized.new(['no'], user: @user, record: @mine)
        assert_equal [['no'], @user, @mine], [error.details, error.user, error.record]
        assert_raises(NotAuthorized) { raise NotAuthorized, { message: 'y' } }

        # a host passing the record as a keyword keeps it in details, as before
        keyword = NotAuthorized.new(record: @mine, message: 'x')
        assert_equal({ record: @mine, message: 'x' }, keyword.details)
        assert_equal [@mine, nil], [keyword.record, keyword.user]
        assert_raises(ArgumentError) { NotAuthorized.new(['no'], colour: 'red') }
      end

      test 'a missing record is no denial' do
        assert_no_difference -> { AuditEvent.where(event: 'access.denied').count } do
          assert_nil Customer.find_by(uuid: 'nope')
        end
      end

      test 'an allowed row publishes nothing' do
        uuid = @mine.uuid
        @user.permissions_hash
        _, events = published_runtime { assert_equal @mine, Customer.find_by(uuid: uuid) }
        assert_empty events
      end

      test 'the decision is unchanged and published at once inside a transaction' do
        payloads = published('access.denied') do
          ActiveRecord::Base.transaction do
            assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied.uuid) }
          end
        end
        assert_equal 1, payloads.size
      end

      # --- nil user ------------------------------------------------------------------

      test 'no user under :bypass is rule.bypassed (nil_user) on find_by and permission_scoped' do
        Current.user = nil
        payloads = published('rule.bypassed') do
          assert_equal @denied, Customer.find_by(uuid: @denied.uuid)
          assert_includes Customer.permission_scoped.to_a, @denied
        end

        assert_equal([%w[nil_user find_by], %w[nil_user permission_scoped]], payloads.map { |p| p[:data].values_at('reason', 'via') })
        assert_equal ['unknown'], payloads.map { |p| p[:actor_type] }.uniq
        assert_nil payloads.first[:subject_user_id]
      end

      test 'no user under :deny and :raise is access.denied (nil_user), stored by default' do
        Current.user = nil
        PermissionForge.configuration.nil_user_strategy = :deny
        assert_difference -> { AuditEvent.where(event: 'access.denied').count }, 2 do
          assert_nil Customer.find_by(uuid: @mine.uuid)
          assert_empty Customer.permission_scoped.to_a
        end

        PermissionForge.configuration.nil_user_strategy = :raise
        assert_difference -> { AuditEvent.where(event: 'access.denied').count }, 2 do
          assert_raises(NotAuthorized) { Customer.find_by(uuid: @mine.uuid) }
          assert_raises(NotAuthorized) { Customer.permission_scoped }
        end
        event = assert_audit_event('access.denied', actor_type: 'unknown', record_type: 'Customer', subject_user_id: nil)
        assert_equal %w[nil_user permission_scoped], event.data.values_at('reason', 'via')
      end

      # --- bypass reasons ------------------------------------------------------------

      test 'view_all and modify_all are rule.bypassed with their own reason, and not stored by default' do
        grant(view_all: true)
        payloads = nil
        assert_no_difference -> { AuditEvent.where(event: 'rule.bypassed').count } do
          payloads = published('rule.bypassed') do
            assert_equal @denied, Customer.find_by(uuid: @denied.uuid)
            assert_includes Customer.permission_scoped.to_a, @denied
          end
        end
        assert_equal([%w[view_all find_by], %w[view_all permission_scoped]], payloads.map { |p| p[:data].values_at('reason', 'via') })
        assert_equal [@user.id.to_s], payloads.map { |p| p[:subject_user_id] }.uniq
        assert_same @user, payloads.first[:objects][:user]

        # modify_all without view_all: a row written past the model's validation
        @resource.update_columns(view_all: false, modify_all: true)
        @user.regenerate_permissions
        payloads = published('rule.bypassed') { Customer.find_by(uuid: @denied.uuid) }
        assert_equal(['modify_all'], payloads.map { |p| p[:data]['reason'] })
      end

      test 'the bypass group is stored when configured' do
        store_runtime(:denied, :bypass)
        grant(view_all: true)
        assert_difference -> { AuditEvent.where(event: 'rule.bypassed').count }, 1 do
          Customer.find_by(uuid: @denied.uuid)
        end
        event = assert_audit_event('rule.bypassed', record_type: 'Customer', subject_user_id: @user.id.to_s)
        assert_equal 'view_all', event.data['reason']
      end

      test 'no rules is rule.bypassed (no_rules)' do
        @rule.destroy!
        @user.reload
        payloads = published('rule.bypassed') do
          Customer.find_by(uuid: @denied.uuid)
          Customer.permission_scoped.to_a
        end
        assert_equal([%w[no_rules find_by], %w[no_rules permission_scoped]], payloads.map { |p| p[:data].values_at('reason', 'via') })
      end

      test 'the rule applier called with no rules reports no_rules' do
        payloads = published('rule.bypassed') do
          PermissionForge::Services::PermissionRuleApplier.scope(model_class: Customer, rules: [], current_user: @user)
          PermissionForge::Services::PermissionRuleApplier.call(model_class: Customer, rules: [], args: [{ id: 1 }], current_user: @user)
        end
        assert_equal([%w[no_rules rule_applier]] * 2, payloads.map { |p| p[:data].values_at('reason', 'via') })
      end

      test 'an unknown bypass reason is refused' do
        published('rule.bypassed') do
          assert_raises(ArgumentError) { Runtime.bypassed(:because, model: Customer, via: 'find_by') }
        end
      end

      # --- auto-scoping: at most once per request ------------------------------------

      test 'auto-scoping reports view_all, no_rules and nil_user once per request per model' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        grant(view_all: true)
        payloads = published('rule.bypassed') { 3.times { Customer.where(name: 'x').to_a } }
        assert_equal([%w[view_all auto_scope]], payloads.map { |p| p[:data].values_at('reason', 'via') })

        next_request!
        grant(view_all: false)
        @rule.destroy!
        @user.reload
        payloads = published('rule.bypassed') { 2.times { Customer.where(name: 'x').to_a } }
        assert_equal([%w[no_rules auto_scope]], payloads.map { |p| p[:data].values_at('reason', 'via') })

        Current.user = nil
        payloads = published('rule.bypassed') { 2.times { Customer.where(name: 'x').to_a } }
        assert_equal([%w[nil_user auto_scope]], payloads.map { |p| p[:data].values_at('reason', 'via') })
      end

      test 'auto-scoping with no user under :deny is access.denied once per request' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        PermissionForge.configuration.nil_user_strategy = :deny
        Current.user = nil
        assert_difference -> { AuditEvent.where(event: 'access.denied').count }, 1 do
          3.times { assert_empty Customer.where(name: 'Test Customer').to_a }
        end
        assert_equal %w[nil_user auto_scope], assert_audit_event('access.denied').data.values_at('reason', 'via')
      end

      test 'a host suspension and a per-model opt-out are reported under auto-scoping, the gem own suspension is not' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        payloads = published('rule.bypassed') do
          Customer.find_by(uuid: @mine.uuid)
          Customer.permission_scoped.to_a
        end
        assert_empty payloads, 'find_by and permission_scoped suspend Level 1 for themselves'

        payloads = published('rule.bypassed') do
          2.times { PermissionForge.without_permission_scope { Customer.where(name: 'x').to_a } }
          Customer.permission_forge_auto_scope = false
          2.times { Customer.where(name: 'x').to_a }
        end
        assert_equal([%w[scope_suspended auto_scope], %w[auto_scope_opt_out auto_scope]],
                     payloads.map { |p| p[:data].values_at('reason', 'via') })
      end

      test 'nothing is reported while Level 1 is off' do
        payloads = published('rule.bypassed') do
          PermissionForge.without_permission_scope { Customer.where(name: 'x').to_a }
          Customer.where(name: 'x').to_a
        end
        assert_empty payloads
      end

      test 'auto-scoped results are unchanged' do
        PermissionForge.configuration.auto_query_scoping = :filter_only
        published('rule.bypassed') do
          uuids = Customer.where.not(uuid: nil).pluck(:uuid)
          assert_includes uuids, @mine.uuid
          assert_not_includes uuids, @denied.uuid
        end
      end

      # --- Level 2 -------------------------------------------------------------------

      test 'an unscoped query found by Level 2 is query.unscoped, once per request per table, without the SQL' do
        PermissionForge.configuration.unscoped_query_detection = :log
        sql = "SELECT * FROM customers WHERE email = 'secret@example.com'"
        payloads = published('query.unscoped') do
          2.times { PermissionForge::Services::UnscopedQueryDetector.check(sql: sql, name: 'Customer Load') }
        end
        assert_equal 1, payloads.size
        assert_equal 'Customer', payloads.first[:record_type]
        assert_equal({ 'model' => 'Customer', 'table' => 'customers', 'mode' => 'log' }, payloads.first[:data].except('call_site'))
        assert_not_includes payloads.first.to_s, 'secret@example.com'
      end
    end
  end
end
