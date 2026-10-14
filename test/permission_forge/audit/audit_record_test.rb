# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # The single emitter: Audit.record stores and publishes, Audit.instrument
  # publishes and stores only the configured runtime groups, and both answer
  # to config.audit_events.
  class AuditRecordTest < ActiveSupport::TestCase
    NOTIFICATION = 'permission_set.created.permission_forge'

    def subscribe(name = NOTIFICATION)
      received = []
      subscriber = ActiveSupport::Notifications.subscribe(name) { |event| received << event.payload }
      yield received
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # The event store refuses every write for the block (minitest 6 has no
    # minitest/mock: the method is defined on the singleton and removed again).
    def with_failing_store
      store = PermissionForge::AuditEvent.method(:store!)
      replace_singleton_method(PermissionForge::AuditEvent, :store!) { |*| raise ActiveRecord::StatementInvalid, 'disk full' }
      yield
    ensure
      replace_singleton_method(PermissionForge::AuditEvent, :store!, store)
    end

    def with_missing_table
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { false }
      PermissionForge::Audit.reset!
      yield
    ensure
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      PermissionForge::Audit.reset!
    end

    def capture_log
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield output
    ensure
      Rails.logger = previous
    end

    # --- record ---------------------------------------------------------------------

    test 'record stores an event with the catalogue category and the context columns' do
      Current.user = create_user(name: 'Ada')
      set = create_permission_set(name: 'Ops')
      event = nil
      Audit::Context.with(source: 'admin_ui', request_id: 'req-1', ip: '10.0.0.1', reason: 'ticket 4') do
        event = Audit.record('permission_set.cloned', record: set, data: { source_uuid: 'abc' })
      end
      assert_instance_of PermissionForge::AuditEvent, event
      assert event.persisted?
      assert_equal 'permission_set.cloned', event.event
      assert_equal 'change', event.category
      assert_equal %w[user], [event.actor_type]
      assert_equal Current.user.id.to_s, event.actor_id
      assert_equal 'Ada', event.actor_label
      assert_equal 'admin_ui', event.source
      assert_equal 'req-1', event.request_id
      assert_equal '10.0.0.1', event.ip
      assert_equal 'ticket 4', event.reason
      assert_equal 'PermissionForge::PermissionSet', event.record_type
      assert_equal set.id.to_s, event.record_id
      assert_equal set.uuid, event.record_uuid
      assert_equal 'Ops', event.record_label
      assert_equal set.id, event.permission_set_id
      assert_equal set.uuid, event.permission_set_uuid
      assert_equal({ 'source_uuid' => 'abc' }, event.data)
      assert_not_nil event.correlation_id
      assert_in_delta Time.current, event.occurred_at, 5
      assert_equal DEFAULT_TEST_ACCOUNT.id, event.account_id
    end

    test 'record without a record or context falls back to unknown actor and the process source' do
      event = Audit.record('report.generated', data: { 'report' => 'stale_assignments', 'count' => 3 })
      assert_equal 'unknown', event.actor_type
      assert_nil event.actor_id
      assert_equal 'service', event.source
      assert_nil event.record_type
      assert_equal({ 'report' => 'stale_assignments', 'count' => 3 }, event.data)
    end

    test 'record takes explicit actor, source, reason, subject and permission set overrides' do
      set = create_permission_set
      user = create_user(name: 'Subject')
      event = Audit.record('erasure.performed', actor: Audit::Actor.new(type: 'system', label: 'rake'), source: 'rake',
                                                reason: 'GDPR request', subject_user_id: user.id, permission_set: set)
      assert_equal ['system', nil, 'rake'], [event.actor_type, event.actor_id, event.actor_label]
      assert_equal 'rake', event.source
      assert_equal 'GDPR request', event.reason
      assert_equal user.id.to_s, event.subject_user_id
      assert_equal set.id, event.permission_set_id
      assert_equal set.uuid, event.permission_set_uuid
    end

    test 'record accepts a user as the actor override' do
      user = create_user(name: 'Ada')
      event = Audit.record('report.generated', actor: user)
      assert_equal ['user', user.id.to_s, 'Ada'], [event.actor_type, event.actor_id, event.actor_label]
    end

    test 'record refuses an event that is not in the catalogue' do
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        assert_raises(Audit::EventCatalog::UnknownEventError) { Audit.record('permission_set.renamed') }
      end
    end

    test 'record refuses an access event: runtime events go through instrument' do
      assert_raises(ArgumentError) { Audit.record('access.denied') }
    end

    test 'data keys are stored as strings' do
      event = Audit.record('report.generated', data: { count: 1, nested: { key: :value } })
      assert_equal({ 'count' => 1, 'nested' => { 'key' => 'value' } }, event.data)
    end

    # --- publishing -------------------------------------------------------------------

    test 'a stored event is published after the transaction commits, once, with the event in the payload' do
      subscribe do |received|
        ActiveRecord::Base.transaction do
          Audit.record('permission_set.created', data: { 'n' => 1 })
          assert_empty received, 'published before the commit'
        end
        assert_equal 1, received.size
        payload = received.first
        assert_equal 'permission_set.created', payload[:event]
        assert_equal 'change', payload[:category]
        assert_equal({ 'n' => 1 }, payload[:data])
        assert payload[:stored]
        assert_instance_of PermissionForge::AuditEvent, payload[:audit_event]
      end
    end

    test 'nothing is published when the transaction rolls back' do
      subscribe do |received|
        assert_no_difference -> { PermissionForge::AuditEvent.count } do
          ActiveRecord::Base.transaction do
            Audit.record('permission_set.created')
            raise ActiveRecord::Rollback
          end
        end
        assert_empty received
      end
    end

    test 'outside a transaction the event is published at once' do
      subscribe do |received|
        Audit.record('permission_set.created')
        assert_equal 1, received.size
      end
    end

    test 'a subscriber that raises is reported and does not break the caller' do
      subscriber = ActiveSupport::Notifications.subscribe(NOTIFICATION) { |*| raise 'subscriber bug' }
      reported = []
      Rails.error.subscribe(reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new)
      capture_log do |log|
        assert_nothing_raised { Audit.record('permission_set.created') }
        assert_match(/subscriber bug/, log.string)
      end
      assert_equal ['subscriber bug'], reported.map(&:message)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
      Rails.error.unsubscribe(reporter)
    end

    test 'a subscriber that raises propagates under audit_hook_failure_strategy = :raise' do
      PermissionForge.configuration.audit_hook_failure_strategy = :raise
      subscriber = ActiveSupport::Notifications.subscribe(NOTIFICATION) { |*| raise 'subscriber bug' }
      assert_raises(RuntimeError) { Audit.record('permission_set.created') }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # --- enabled? ---------------------------------------------------------------------

    test 'enabled? is true under :auto when the table exists' do
      assert_equal :auto, PermissionForge.configuration.audit_events
      assert Audit.enabled?
    end

    test 'enabled? follows true and false' do
      PermissionForge.configuration.audit_events = false
      assert_not Audit.enabled?
      PermissionForge.configuration.audit_events = true
      assert Audit.enabled?
    end

    test 'with audit_events = false record stores nothing but still publishes' do
      PermissionForge.configuration.audit_events = false
      subscribe do |received|
        assert_no_difference -> { PermissionForge::AuditEvent.count } do
          assert_nil Audit.record('permission_set.created')
        end
        assert_equal 1, received.size
        assert_not received.first[:stored]
        assert_nil received.first[:audit_event]
      end
    end

    test 'under :auto a missing table degrades: nothing stored, a warning logged once, changes still work' do
      with_missing_table do
        capture_log do |log|
          assert_not Audit.enabled?
          assert_not Audit.enabled?
          assert_equal 1, log.string.lines.grep(/audit/i).size
          assert_match(/table.*audit_events.*not found/i, log.string)
          assert_nil Audit.record('permission_set.created')
          set = create_permission_set(name: 'Still works')
          assert set.persisted?
        end
      end
    end

    test 'the table check is cached per table name and reset by reset!' do
      calls = 0
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) do
        calls += 1
        true
      end
      Audit.reset!
      3.times { Audit.enabled? }
      assert_equal 1, calls
      Audit.reset!
      Audit.enabled?
      assert_equal 2, calls
    ensure
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      Audit.reset!
    end

    test 'a database that is not reachable counts as no table and is asked again' do
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { raise ActiveRecord::ConnectionNotEstablished }
      Audit.reset!
      capture_log { assert_not Audit.enabled? }
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      assert Audit.enabled?
    ensure
      Audit.reset!
    end

    test 'verify_table! logs the boot warning when :auto finds no table and is silent otherwise' do
      capture_log do |log|
        Audit.verify_table!
        assert_no_match(/audit_events/, log.string)
      end
      with_missing_table do
        capture_log do |log|
          Audit.verify_table!
          assert_match(/audit_events/, log.string)
        end
      end
    end

    # --- failure strategies -----------------------------------------------------------

    test 'a failing store raises EventNotRecordedError under the default change failure strategy' do
      with_failing_store do
        error = assert_raises(Audit::EventNotRecordedError) { Audit.record('permission_set.created') }
        assert_kind_of ActiveRecord::StatementInvalid, error.cause
      end
    end

    test 'a failing store is reported and swallowed under :report' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      reported = []
      Rails.error.subscribe(reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new)
      with_failing_store do
        capture_log do |log|
          assert_nil Audit.record('permission_set.created')
          assert_match(/disk full/, log.string)
        end
      end
      assert_equal 1, reported.size
      assert_kind_of ActiveRecord::StatementInvalid, reported.first
    ensure
      Rails.error.unsubscribe(reporter)
    end

    test 'a failing store is only logged under :log' do
      PermissionForge.configuration.audit_change_failure_strategy = :log
      reported = []
      Rails.error.subscribe(reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new)
      with_failing_store do
        capture_log do |log|
          assert_nil Audit.record('permission_set.created')
          assert_match(/disk full/, log.string)
        end
      end
      assert_empty reported
    ensure
      Rails.error.unsubscribe(reporter)
    end

    # --- instrument -------------------------------------------------------------------

    test 'instrument publishes an access event without storing it' do
      subscribe('rule.bypassed.permission_forge') do |received|
        assert_no_difference -> { PermissionForge::AuditEvent.count } do
          assert_nil Audit.instrument('rule.bypassed', data: { 'reason' => 'view_all' }, source: 'runtime')
        end
        assert_equal 1, received.size
        assert_equal 'rule.bypassed', received.first[:event]
        assert_equal 'runtime', received.first[:source]
        assert_not received.first[:stored]
      end
    end

    test 'instrument stores the groups listed in audit_runtime_events (denied by default)' do
      event = Audit.instrument('access.denied', data: { 'resource' => 'Customer' })
      assert_instance_of PermissionForge::AuditEvent, event
      assert_equal 'access', event.category
      assert_equal 'runtime', event.source
      assert_nil Audit.instrument('field.access')
      PermissionForge.configuration.audit_runtime_events = %i[denied field_read]
      assert_instance_of PermissionForge::AuditEvent, Audit.instrument('field.access')
    end

    test 'instrument does nothing at all when nobody listens and the group is not stored' do
      assert_not ActiveSupport::Notifications.notifier.listening?('rule.bypassed.permission_forge')
      resolve_actor = Audit::Actor.method(:current)
      store = PermissionForge::AuditEvent.method(:store!)
      touched = []
      replace_singleton_method(PermissionForge::AuditEvent, :store!) { |*| touched << :store }
      replace_singleton_method(Audit::Actor, :current) { touched << :actor }
      assert_nil Audit.instrument('rule.bypassed', data: { 'reason' => 'nil_user' })
      assert_empty touched
    ensure
      replace_singleton_method(PermissionForge::AuditEvent, :store!, store)
      replace_singleton_method(Audit::Actor, :current, resolve_actor)
    end

    test 'a nil source, actor or reason in the payload falls back instead of raising' do
      Audit::Context.with(source: 'api', reason: 'ctx') do
        event = Audit.record('report.generated', source: nil, actor: nil, reason: nil)
        assert_equal %w[api ctx unknown], [event.source, event.reason, event.actor_type]
      end
      assert_equal 'runtime', Audit.instrument('access.denied', source: nil).source
    end

    test 'instrument refuses an unknown event and a non-access event' do
      assert_raises(Audit::EventCatalog::UnknownEventError) { Audit.instrument('access.nope') }
      assert_raises(ArgumentError) { Audit.instrument('permission_set.created') }
    end

    test 'a failing runtime store follows audit_hook_failure_strategy and never breaks the request' do
      with_failing_store do
        capture_log do |log|
          assert_nil Audit.instrument('access.denied')
          assert_match(/disk full/, log.string)
        end
        PermissionForge.configuration.audit_hook_failure_strategy = :raise
        assert_raises(ActiveRecord::StatementInvalid) { Audit.instrument('access.denied') }
      end
    end

    test 'a stored runtime event is published too' do
      subscribe('access.denied.permission_forge') do |received|
        Audit.instrument('access.denied')
        assert_equal 1, received.size
        assert received.first[:stored]
      end
    end

    # --- correlation ------------------------------------------------------------------

    test 'events of one transaction share a correlation id, and the next transaction gets another' do
      first = ActiveRecord::Base.transaction { [Audit.record('permission_set.created'), Audit.record('resource.created')] }
      second = ActiveRecord::Base.transaction { Audit.record('permission_set.created') }
      assert_equal first.first.correlation_id, first.last.correlation_id
      assert_not_equal first.first.correlation_id, second.correlation_id
    end

    test 'a savepoint inside the transaction keeps the correlation id of the outermost one' do
      ids = []
      ActiveRecord::Base.transaction do
        ids << Audit.record('permission_set.created').correlation_id
        ActiveRecord::Base.transaction(requires_new: true) { ids << Audit.record('resource.created').correlation_id }
        ids << Audit.record('resource.destroyed').correlation_id
      end
      assert_equal 1, ids.uniq.size
    end

    test 'a correlate block wins over the transaction' do
      Audit.correlate('batch-1') do
        ActiveRecord::Base.transaction { assert_equal 'batch-1', Audit.record('permission_set.created').correlation_id }
      end
    end

    test 'events outside any transaction or block each get a fresh correlation id' do
      a = Audit.record('report.generated')
      b = Audit.record('report.generated')
      assert_not_nil a.correlation_id
      assert_not_equal a.correlation_id, b.correlation_id
    end
  end
end
