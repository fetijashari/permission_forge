# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require_relative 'runtime_support'

module PermissionForge
  module Audit
    # The plumbing under the runtime events: the gate, the subscribers (log,
    # legacy hooks), failure strategies, re-entrancy and the cache events.
    class RuntimePlumbingTest < ActiveSupport::TestCase
      include RuntimeSupport

      NotAuthorized = PermissionForge::Concerns::PermissionScopedFindable::NotAuthorizedError

      setup do
        @user = create_user(name: 'Ada')
        @set = create_permission_set
        create_permission_set_user(user: @user, permission_set: @set)
        @resource = create_resource(permission_set: @set, name: 'Customer')
        create_resource_field(resource: @resource, name: 'email', label: 'Email', read_access: true, mask_access: true,
                              mask_strategy: 'email')
        create_permission_set_rule(permission_set: @set, resource: @resource, include_nulls: false)
        @denied = create_customer(supplier_id: @user.id + 1000, email: 'john@example.com')
        @denied_uuid = @denied.uuid
        @user.regenerate_permissions
        Current.user = @user
        @customer = Customer.find(@denied.id)
      end

      teardown do
        PermissionForge.configuration.on_field_filtered = nil
        PermissionForge.configuration.on_rule_bypass = nil
        @subscribers&.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
      end

      def subscribe(pattern, callable = nil, &)
        (@subscribers ||= []) << ActiveSupport::Notifications.subscribe(pattern, callable, &)
      end

      def with_logger
        io = StringIO.new
        previous = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = previous
      end

      def with_error_reports
        reports = []
        reporter = Rails.error
        reporter.define_singleton_method(:report) { |error, **options| reports << [error, options] }
        yield
        reports
      ensure
        reporter.singleton_class.send(:remove_method, :report)
      end

      # --- the gate ----------------------------------------------------------------------

      test 'the gate opens and shuts with a subscription, a stored group and a legacy hook' do
        gate = Gate.for('field.access')
        assert_not gate.open?

        subscriber = ActiveSupport::Notifications.subscribe('field.access.permission_forge') { |*| nil }
        assert gate.open?
        ActiveSupport::Notifications.unsubscribe(subscriber)
        assert_not gate.open?

        pattern = ActiveSupport::Notifications.subscribe(/access/) { |*| nil }
        assert gate.open?
        ActiveSupport::Notifications.unsubscribe(pattern)
        assert_not gate.open?

        store_runtime(:field_read)
        assert gate.open?
        store_runtime(:denied)
        assert_not gate.open?

        PermissionForge.configuration.on_field_filtered = ->(**) {}
        assert gate.open?
        PermissionForge.configuration.on_field_filtered = nil
        assert_not gate.open?
      end

      test 'the gate notices a new notifier and a new configuration' do
        gate = Gate.for('field.access')
        assert_not gate.open?
        previous = ActiveSupport::Notifications.notifier
        fresh = ActiveSupport::Notifications::Fanout.new
        fresh.subscribe('field.access.permission_forge') { |*| nil }
        ActiveSupport::Notifications.notifier = fresh
        assert gate.open?
      ensure
        ActiveSupport::Notifications.notifier = previous
        assert_not gate.open?
      end

      test 'a host subscriber that says it is silenced still opens the gate; instrument? asks it' do
        silenced = Class.new do
          attr_accessor :quiet

          def call(*) = nil
          def silenced?(_name) = quiet
        end.new
        silenced.quiet = true
        subscribe('field.access.permission_forge', silenced)
        assert Gate.for('field.access').open?
        assert_not Audit.instrument?('field.access')
        silenced.quiet = false
        assert Audit.instrument?('field.access')
      end

      test 'the audit_runtime_events array is frozen (a group pushed in place would pass the gate by)' do
        assert_raises(FrozenError) { PermissionForge.configuration.audit_runtime_events << :bypass }
        assert_predicate PermissionForge::Configuration.new.audit_runtime_events, :frozen?
      end

      # --- subscribers -----------------------------------------------------------------

      test 'the log subscriber writes one JSON line per event, without labels, only when switched on' do
        assert_empty(with_logger { assert_raises(NotAuthorized) { Customer.find_by(uuid: @denied_uuid) } }.lines.grep(/audit/))

        PermissionForge.configuration.audit_log_subscriber = true
        log = with_logger do
          assert_raises(NotAuthorized) { Customer.find_by(uuid: @denied_uuid) }
          ActiveSupport::Notifications.instrument('cache_failure.permission_forge', {})
        end
        lines = log.lines.grep(/\[PermissionForge\] audit /)
        assert_equal 1, lines.size
        entry = JSON.parse(lines.first.split('[PermissionForge] audit ', 2).last)
        assert_equal %w[access.denied access user runtime Customer], entry.values_at('event', 'category', 'actor_type', 'source', 'record_type')
        assert_equal @user.id.to_s, entry['actor_id']
        assert_not entry.key?('actor_label')
        assert_equal true, entry['stored']
      ensure
        PermissionForge.configuration.audit_log_subscriber = false
      end

      test 'a subscriber that raises follows audit_hook_failure_strategy' do
        subscribe('field.access.permission_forge') { |*| raise 'subscriber down' }

        reports = with_error_reports { assert_equal 'j***@example.com', @customer.email }
        assert_equal(['subscriber down'], reports.map { |error, _| error.message })

        PermissionForge.configuration.audit_hook_failure_strategy = :log
        log = nil
        reports = with_error_reports { log = with_logger { assert_equal 'j***@example.com', @customer.email } }
        assert_empty reports
        assert_includes log, 'subscriber down'

        PermissionForge.configuration.audit_hook_failure_strategy = :raise
        assert_raises(StandardError) { @customer.email }
      end

      test 'a legacy hook that raises follows the strategy too, one call at a time' do
        calls = 0
        PermissionForge.configuration.on_field_filtered = lambda { |**|
          calls += 1
          raise 'hook down'
        }
        reports = with_error_reports { @customer.attributes }
        assert_operator calls, :>, 1, 'every decision is still handed to the hook'
        assert_equal calls, reports.size

        PermissionForge.configuration.on_field_filtered = nil
        PermissionForge.configuration.on_rule_bypass = ->(**) { raise 'bypass hook down' }
        @resource.update!(view_all: true)
        @user.reload
        PermissionForge.configuration.audit_hook_failure_strategy = :raise
        error = assert_raises(RuntimeError) { Customer.find_by(uuid: @denied_uuid) }
        assert_equal 'bypass hook down', error.message
      end

      # --- re-entrancy -----------------------------------------------------------------

      test 'a subscriber that reads masked attributes and runs permission checks does not loop or publish' do
        seen = []
        subscribe(/\.permission_forge\z/) do |name, *, payload|
          next unless payload[:category] == 'access'

          seen << name
          payload[:objects][:record]&.email
          @user.can_read?('Customer')
          Customer.find_by(uuid: @denied_uuid)
        rescue NotAuthorized
          nil
        end

        assert_equal 'j***@example.com', @customer.email
        assert_equal ['field.access.permission_forge'], seen
        seen.clear
        assert_raises(NotAuthorized) { Customer.find_by!(uuid: @denied_uuid) }
        assert_equal ['access.denied.permission_forge'], seen
      end

      test 'a payload that reads a masked attribute does not loop; one that raises is reported' do
        seen = published('field.access') do
          Audit.instrument('field.access') { { record: @customer, data: { 'masked' => [@customer.email] } } }
        end
        assert_equal 1, seen.size

        reports = with_error_reports do
          assert_nil Audit.instrument('access.denied') { raise 'cannot build' }
        end
        assert_equal(['cannot build'], reports.map { |error, _| error.message })
      end

      test 'nothing is emitted while emitting' do
        Audit.send(:emitting) do
          assert Audit.emitting?
          assert_not Audit.instrument?('access.denied')
          assert_no_difference(-> { AuditEvent.count }) { assert_nil Audit.instrument('access.denied') }
        end
        assert_not Audit.emitting?
      end

      # --- the legacy hooks alone: no event is built ---------------------------------------

      def counting_recorders
        built = 0
        original = Recorder.method(:new)
        Recorder.define_singleton_method(:new) do |*args, **kw|
          built += 1
          original.call(*args, **kw)
        end
        yield
        built
      ensure
        Recorder.singleton_class.send(:remove_method, :new)
      end

      test 'with only a legacy hook listening, decisions reach it without building an event' do
        fields = []
        bypasses = []
        # Customer only: User may be masked in this process too (other tests)
        PermissionForge.configuration.on_field_filtered = ->(**args) { fields << args if args[:resource_name] == 'Customer' }
        PermissionForge.configuration.on_rule_bypass = ->(**args) { bypasses << args }
        @resource.update!(view_all: true)
        @user.reload
        @user.permissions_hash

        assert_equal [Audit::Subscribers::LegacyHooks::FieldFiltered], Gate.for('field.access').direct_listeners.map(&:class)
        built = counting_recorders do
          assert_equal 'j***@example.com', @customer.email
          assert_equal @customer, Customer.find_by(uuid: @denied_uuid)
        end

        assert_equal 0, built
        assert_equal([['Customer', :email, :masked, @user]], fields.map { |a| a.values_at(:resource_name, :field_name, :action, :user) })
        assert_equal [{ user: @user, resource: 'Customer', reason: :view_all_or_modify_all }], bypasses
      end

      test 'another listener, a stored group or the log subscriber take the full path' do
        PermissionForge.configuration.on_field_filtered = ->(**) {}
        subscribe('field.access.permission_forge') { |*| nil }
        assert_nil Gate.for('field.access').direct_listeners
        assert_operator(counting_recorders { @customer.email }, :>, 0)
        @subscribers.each { |subscriber| ActiveSupport::Notifications.unsubscribe(subscriber) }
        @subscribers.clear

        store_runtime(:field_read)
        assert_nil Gate.for('field.access').direct_listeners
        store_runtime(:denied)
        PermissionForge.configuration.audit_log_subscriber = true
        assert_nil Gate.for('field.access').direct_listeners
      ensure
        PermissionForge.configuration.audit_log_subscriber = false
      end

      # --- a stored group with auditing off ------------------------------------------------

      test 'a stored group with auditing off (or no table) collects nothing' do
        store_runtime(:field_read)
        PermissionForge.configuration.audit_events = false
        assert_not Audit.instrument?('field.access')
        frames = 0
        original = FieldAccess::Frame.method(:new)
        FieldAccess::Frame.define_singleton_method(:new) do |*args, **kw|
          frames += 1
          original.call(*args, **kw)
        end
        @customer.email
        assert_equal 0, frames
      ensure
        FieldAccess::Frame.singleton_class.send(:remove_method, :new)
      end

      # --- cache events ----------------------------------------------------------------

      test 'a rebuilt and an invalidated permission hash are published, stored only with the cache group' do
        payloads = published('permissions.rebuilt') do
          @user.regenerate_permissions
          PermissionForge.cache.clear
          User.find(@user.id).permissions_hash
        end
        assert_equal([false, true], payloads.map { |p| p[:data]['read_through'] })
        assert_equal [['User', @user.id.to_s, @user.id.to_s]], payloads.map { |p| p.values_at(:record_type, :record_id, :subject_user_id) }.uniq

        payloads = published('permissions.invalidated') { @user.invalidate_permissions }
        # the memory store of the suite lives in this process; a test runs in no request
        assert_equal([{ 'tenant_id' => nil, 'confirmed' => true, 'process_local' => true, 'in_request' => false }],
                     payloads.map { |p| p[:data] })

        # a subscriber that reads the hash gets the state after the invalidation
        seen = []
        subscribe('permissions.invalidated.permission_forge') do |*|
          seen << @user.permissions_hash.dig(:permissions, :resources, :Customer, :permissions, :view_all)
        end
        @user.permissions_hash
        @resource.update_column(:view_all, true)
        @user.invalidate_permissions
        assert_equal [true], seen

        assert_no_difference(-> { AuditEvent.where(event: 'permissions.invalidated').count }) { @user.invalidate_permissions }
        store_runtime(:cache)
        assert_difference(-> { AuditEvent.where(event: 'permissions.invalidated').count }, 1) { @user.invalidate_permissions }
      end
    end
  end
end
