# frozen_string_literal: true

require 'test_helper'
require_relative 'runtime_support'

module PermissionForge
  module Audit
    # action.denied and rule.bypassed from the controller action guard.
    class ActionDecisionEventsTest < ActiveSupport::TestCase
      include RuntimeSupport

      setup do
        @user = create_user(name: 'Grace Hopper')
        @set = create_permission_set
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @set)
        Current.user = @user
      end

      def authorize(action, klass = ::CustomersController)
        klass.new.tap { |controller| controller.action_name = action }.send(:pf_authorize_action!)
      end

      test 'a denied action is stored as action.denied and the error carries the user' do
        error = nil
        assert_difference -> { AuditEvent.where(event: 'action.denied').count }, 1 do
          error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize('destroy') }
        end

        assert_same @user, error.user
        assert_nil error.record
        assert_equal [:crud_denied, 'Customer', 'destroy'], [error.reason, error.resource, error.action]
        event = assert_audit_event('action.denied', record_type: 'Customer', subject_user_id: @user.id.to_s,
                                                    actor_id: @user.id.to_s, actor_label: 'Grace Hopper', source: 'runtime')
        assert_equal({ 'model' => 'Customer', 'reason' => 'crud_denied', 'via' => 'action_guard', 'action' => 'destroy',
                       'controller' => 'customers', 'action_name' => 'destroy' }, event.data)
      end

      test 'a custom action some set manages and the user lacks is action.denied (action_denied)' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)
        assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize('export') }
        assert_equal 'action_denied', assert_audit_event('action.denied').data['reason']
      end

      test 'a granted action publishes nothing' do
        payloads = published('action.denied') { authorize('index') }
        payloads += published('rule.bypassed') { authorize('show') }
        assert_empty payloads
      end

      test 'no user is action.denied under :deny and rule.bypassed (nil_user) under :bypass' do
        Current.user = nil
        payloads = published('rule.bypassed') { authorize('destroy') }
        assert_equal([%w[nil_user action_guard]], payloads.map { |p| p[:data].values_at('reason', 'via') })
        assert_equal 'unknown', payloads.first[:actor_type]

        PermissionForge.configuration.nil_user_strategy = :deny
        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize('destroy') }
        assert_nil error.user
        assert_equal 'nil_user_denied', assert_audit_event('action.denied', actor_type: 'unknown').data['reason']
      end

      test 'the bypass lambda is rule.bypassed (guard_bypass)' do
        PermissionForge.configuration.action_guard_bypass = ->(_user, _controller) { true }
        payloads = published('rule.bypassed') { authorize('destroy') }
        assert_equal([%w[guard_bypass action_guard]], payloads.map { |p| p[:data].values_at('reason', 'via') })
        assert_equal 'destroy', payloads.first[:data]['action_name']
      end

      test 'an action nobody manages is rule.bypassed (no_rules) under :allow and denied otherwise' do
        payloads = published('rule.bypassed') { authorize('archive') }
        assert_equal([%w[no_rules action_guard]], payloads.map { |p| p[:data].values_at('reason', 'via') })

        PermissionForge.configuration.unconfigured_action_strategy = :block
        assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize('archive') }
        assert_equal 'action_not_managed_blocked', assert_audit_event('action.denied').data['reason']
      end

      test 'the error is built as before by hosts' do
        error = PermissionForge::ActionNotAuthorizedError.new(resource: 'Customer', action: 'merge', controller_path: 'customers')
        assert_nil error.user
        assert_nil error.record
        assert_equal "Not authorized to run 'merge' on Customer (customers)", error.message
        customer = create_customer
        error = PermissionForge::ActionNotAuthorizedError.new(resource: 'Customer', action: 'merge', controller_path: 'c',
                                                              user: @user, record: customer)
        assert_equal [@user, customer], [error.user, error.record]
      end

      test 'Authorizer.allowed? (button checks) publishes nothing' do
        payloads = published('rule.bypassed') do
          PermissionForge::ControllerActions::Authorizer.allowed?(controller_path: 'customers', action_name: 'archive')
        end
        assert_empty payloads
      end
    end
  end
end
