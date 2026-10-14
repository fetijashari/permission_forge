# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # What happens when an event cannot be built or written: the change path
  # fails closed even for a caller that rescues, the runtime path never
  # breaks the request, and neither leaves the caller's transaction broken.
  class AuditFailureTest < ActiveSupport::TestCase
    # A fresh exception each time: Rails.error reports an instance once.
    def with_failing_store(build_error = -> { ActiveRecord::StatementInvalid.new('disk full') })
      store = PermissionForge::AuditEvent.method(:store!)
      replace_singleton_method(PermissionForge::AuditEvent, :store!) { |*| raise build_error.call }
      yield
    ensure
      replace_singleton_method(PermissionForge::AuditEvent, :store!, store)
    end

    def reporting
      reported = []
      reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new
      Rails.error.subscribe(reporter)
      yield reported
    ensure
      Rails.error.unsubscribe(reporter)
    end

    def capture_log
      output = StringIO.new
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield output
    ensure
      Rails.logger = previous
    end

    # --- M2: a caller that rescues inside its transaction ------------------------------

    test 'a change whose event failed raises EventNotRecordedError with the store error as cause' do
      with_failing_store do
        error = assert_raises(Audit::EventNotRecordedError) { create_permission_set(name: 'Never') }
        assert_equal 'permission_set.created', error.event
        assert_kind_of ActiveRecord::StatementInvalid, error.cause
        assert_match(/permission_set\.created.*could not be written/, error.message)
      end
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Never')
    end

    test 'a caller that rescues the error inside its transaction cannot commit the change' do
      set = create_permission_set(name: 'Ops')
      error = with_failing_store do
        assert_raises(Audit::EventNotRecordedError) do
          ActiveRecord::Base.transaction do
            begin
              create_permission_set(name: 'Rescued')
            rescue Audit::EventNotRecordedError
              nil
            end
            begin
              set.update!(name: 'Rescued rename')
            rescue Audit::EventNotRecordedError
              nil
            end
            Account.create!(name: 'Innocent bystander')
          end
        end
      end
      assert_match(/rolled back at commit/, error.message)
      assert_kind_of ActiveRecord::StatementInvalid, error.cause
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Rescued')
      assert_equal 'Ops', set.reload.name
      assert_nil Account.find_by(name: 'Innocent bystander'), 'the whole transaction rolled back'
    end

    # Rails rescues a RecordInvalid inside `save` and answers false; the
    # audit event's own validation failing must not pass for that.
    test 'a non-bang save whose event failed does not commit either' do
      set = create_permission_set(name: 'Ops')
      with_failing_store(-> { ActiveRecord::RecordInvalid.new(PermissionForge::AuditEvent.new) }) do
        error = assert_raises(Audit::EventNotRecordedError) { set.update(name: 'Quiet') }
        assert_kind_of ActiveRecord::RecordInvalid, error.cause
        assert_raises(Audit::EventNotRecordedError) do
          ActiveRecord::Base.transaction do
            set.update(name: 'Quieter')
          rescue Audit::EventNotRecordedError
            nil
          end
        end
      end
      assert_equal 'Ops', set.reload.name
    end

    test 'a savepoint the caller rolls back drops the guard with the change' do
      kept = nil
      ActiveRecord::Base.transaction do
        with_failing_store do
          ActiveRecord::Base.transaction(requires_new: true) do
            begin
              create_permission_set(name: 'Inner')
            rescue Audit::EventNotRecordedError
              nil
            end
            raise ActiveRecord::Rollback
          end
        end
        kept = create_permission_set_group(name: 'Kept')
      end
      assert PermissionForge::PermissionSetGroup.exists?(kept.id)
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Inner')
    end

    test 'under :report the change goes through and the error is reported, not raised' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      reporting do |reported|
        set = nil
        with_failing_store do
          ActiveRecord::Base.transaction do
            set = create_permission_set(name: 'Through')
            set.update!(name: 'Through 2')
          end
        end
        assert_equal 'Through 2', set.reload.name
        assert_equal 2, reported.size
      end
    end

    # --- M1: a failure while building the event -----------------------------------------

    test 'an actor that cannot be read is a failure of the event, not of the subscriber: the change goes through under :report' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      subscriber = ActiveSupport::Notifications.subscribe(/\.permission_forge\z/) { |*| nil }
      Current.user = Object.new
      reporting do |reported|
        capture_log do
          set = create_permission_set(name: 'Bad actor')
          assert set.persisted?
          assert_equal 0, audit_events_for(set).count
        end
        assert_equal 1, reported.size
        assert_kind_of NoMethodError, reported.first
      end
    ensure
      Current.user = nil
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test 'an actor that cannot be read rolls the change back under :raise' do
      Current.user = Object.new
      error = assert_raises(Audit::EventNotRecordedError) { create_permission_set(name: 'Bad actor') }
      assert_kind_of NoMethodError, error.cause
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Bad actor')
    ensure
      Current.user = nil
    end

    test 'instrument with a payload that cannot be built returns nil and reports under hook :report, with or without storage' do
      subscriber = ActiveSupport::Notifications.subscribe(/\.permission_forge\z/) { |*| nil }
      reporting do |reported|
        capture_log do
          assert_nil Audit.instrument('access.denied', actor: 'alice')
          PermissionForge.configuration.audit_runtime_events = []
          assert_nil Audit.instrument('access.denied', actor: 'alice')
        end
        assert_equal 2, reported.size
      end
      PermissionForge.configuration.audit_hook_failure_strategy = :raise
      assert_raises(NoMethodError) { Audit.instrument('access.denied', actor: 'alice') }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # --- m4: a raising current_user_resolver -------------------------------------------

    test 'a raising current_user_resolver makes the actor unknown and is reported' do
      PermissionForge.configuration.current_user_resolver = -> { raise 'session store down' }
      reporting do |reported|
        capture_log do
          event = Audit.record('report.generated')
          assert_equal 'unknown', event.actor_type
          set = create_permission_set(name: 'Still recorded')
          assert_equal 'unknown', audit_events_for(set).first.actor_type
        end
        assert_equal 2, reported.size
      end
      PermissionForge.configuration.audit_hook_failure_strategy = :raise
      assert_raises(RuntimeError) { Audit::Actor.current }
    ensure
      PermissionForge.configuration.current_user_resolver = -> { Current.user }
    end

    # --- M3: host records -------------------------------------------------------------

    test 'a host record is referenced by base class, id and raw uuid — never through its readers' do
      supplier = create_supplier(name: 'Acme')
      supplier.define_singleton_method(:name) { raise 'reader guarded' }
      supplier.define_singleton_method(:uuid) { raise 'reader guarded' }
      event = Audit.record('erasure.performed', record: supplier)
      assert_equal 'Supplier', event.record_type
      assert_equal supplier.id.to_s, event.record_id
      assert_equal supplier.read_attribute_before_type_cast('uuid'), event.record_uuid
      assert_nil event.record_label
      labelled = Audit.record('erasure.performed', record: supplier, record_label: 'Acme (erased)')
      assert_equal 'Acme (erased)', labelled.record_label
    end

    test 'a host record without a uuid column or outside ActiveRecord is still referenced' do
      account = Account.create!(name: 'Tenant')
      event = Audit.record('report.generated', record: account)
      assert_equal %w[Account], [event.record_type]
      assert_equal account.id.to_s, event.record_id
      assert_nil event.record_uuid
      plain = Struct.new(:id).new(9)
      event = Audit.record('report.generated', record: plain)
      assert_equal '9', event.record_id
      assert_nil event.record_uuid
    end

    # --- m2: a missing table is looked for again -----------------------------------------

    test 'a missing table is believed for a while, then looked for again without reset!' do
      answers = [false]
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) { answers.first }
      Audit.reset!
      capture_log do |log|
        assert_not Audit.enabled?
        answers[0] = true
        assert_not Audit.enabled?, 'the negative answer is believed for missing_table_recheck seconds'
        Audit.missing_table_recheck = 0
        assert Audit.enabled?
        assert Audit.enabled?
        assert_equal 1, log.string.lines.grep(/not found/).size, 'warned once'
      end
    ensure
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      Audit.missing_table_recheck = Audit::MISSING_TABLE_RECHECK
      Audit.reset!
    end

    test 'a table that was found is remembered for the process' do
      calls = 0
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) do
        calls += 1
        true
      end
      Audit.reset!
      5.times { assert Audit.enabled? }
      assert_equal 1, calls
    ensure
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      Audit.reset!
    end

    # --- m3: the hot path --------------------------------------------------------------

    test 'instrument? says whether instrumenting would do anything' do
      assert_not Audit.instrument?('field.access')
      assert Audit.instrument?('access.denied'), 'the denied group is stored by default'
      subscriber = ActiveSupport::Notifications.subscribe('field.access.permission_forge') { |*| nil }
      assert Audit.instrument?('field.access')
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test 'the payload block is evaluated only when the event is stored or heard' do
      evaluated = 0
      assert_nil(Audit.instrument('field.access') { evaluated += 1 and { data: { 'x' => 1 } } })
      assert_equal 0, evaluated
      received = []
      subscriber = ActiveSupport::Notifications.subscribe('field.access.permission_forge') { |event| received << event.payload }
      Audit.instrument('field.access', reason: 'why') { evaluated += 1 and { data: { 'x' => 1 }, record_label: 'Customer#1' } }
      assert_equal 1, evaluated
      assert_equal({ 'x' => 1 }, received.first[:data])
      assert_equal 'Customer#1', received.first[:record_label]
      assert_equal 'why', received.first[:reason]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test 'instrument does not consult the table when the group is not stored and nobody listens' do
      checks = 0
      replace_singleton_method(PermissionForge::AuditEvent, :table_exists?) do
        checks += 1
        true
      end
      Audit.reset!
      assert_nil Audit.instrument('field.access', data: { 'x' => 1 })
      assert_equal 0, checks
    ensure
      PermissionForge::AuditEvent.singleton_class.send(:remove_method, :table_exists?)
      Audit.reset!
    end
  end

  # Real transactions and a real database-level failure of the INSERT (a
  # duplicate uuid on the unique index): on PostgreSQL a failed statement
  # aborts the transaction it ran in, so a swallowed failure must run in a
  # savepoint or the caller's COMMIT silently becomes a ROLLBACK.
  class AuditStoreFailureTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    teardown do
      PermissionForge.configuration.uuid_generator = -> { SecureRandom.uuid }
      PermissionForge.configuration.audit_change_failure_strategy = :raise
      PermissionForge::PermissionSetGroup.unscoped.delete_all
      PermissionForge::PermissionSet.unscoped.delete_all
      PermissionForge::AuditEvent.unscoped.delete_all
    end

    # The next `times` event uuids collide with a stored event. The block runs
    # under one correlation id so the generator is only asked for event uuids
    # (the fixtures pass their own uuids).
    def with_duplicate_event_uuid(times: 1, &)
      existing = PermissionForge::Audit.record('report.generated')
      original = PermissionForge.configuration.uuid_generator
      remaining = times
      PermissionForge.configuration.uuid_generator = lambda {
        remaining -= 1
        remaining >= 0 ? existing.uuid : SecureRandom.uuid
      }
      PermissionForge::Audit.correlate('store-failure', &)
    ensure
      PermissionForge.configuration.uuid_generator = original
    end

    def reporting
      reported = []
      reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new
      Rails.error.subscribe(reporter)
      yield reported
    ensure
      Rails.error.unsubscribe(reporter)
    end

    def quietly
      previous = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(StringIO.new)
      yield
    ensure
      Rails.logger = previous
    end

    test 'under :report a failed INSERT leaves the host transaction usable and the change committed' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      reporting do |reported|
        group = nil
        quietly do
          with_duplicate_event_uuid do
            ActiveRecord::Base.transaction do
              create_permission_set(name: 'Through')
              group = create_permission_set_group(name: 'After the failure')
            end
          end
        end
        assert PermissionForge::PermissionSet.unscoped.exists?(name: 'Through')
        assert PermissionForge::PermissionSetGroup.unscoped.exists?(name: 'After the failure')
        assert_equal 1, PermissionForge::AuditEvent.unscoped.for_record(group).count, 'the audit table is writable again'
        assert_equal 1, reported.size
        assert_kind_of ActiveRecord::RecordNotUnique, reported.first
      end
    end

    test 'a failed runtime store never breaks the request that was denied' do
      reporting do |reported|
        quietly do
          with_duplicate_event_uuid do
            ActiveRecord::Base.transaction do
              assert_nil Audit.instrument('access.denied', data: { 'model' => 'Customer' })
              create_permission_set(name: 'After the denial')
            end
          end
        end
        assert PermissionForge::PermissionSet.unscoped.exists?(name: 'After the denial')
        assert_equal 1, reported.size
      end
    end

    test 'under :raise a failed INSERT rescued inside the host transaction still fails the commit' do
      error = assert_raises(Audit::EventNotRecordedError) do
        with_duplicate_event_uuid do
          ActiveRecord::Base.transaction do
            begin
              create_permission_set(name: 'Rescued')
            rescue Audit::EventNotRecordedError
              nil
            end
            create_permission_set_group(name: 'Also lost')
          end
        end
      end
      assert_kind_of ActiveRecord::RecordNotUnique, error.cause
      assert_not PermissionForge::PermissionSet.unscoped.exists?(name: 'Rescued')
      assert_not PermissionForge::PermissionSetGroup.unscoped.exists?(name: 'Also lost')
    end

    test 'under :raise a failed INSERT outside any host transaction rolls the change back' do
      with_duplicate_event_uuid do
        assert_raises(Audit::EventNotRecordedError) { create_permission_set(name: 'Alone') }
      end
      assert_not PermissionForge::PermissionSet.unscoped.exists?(name: 'Alone')
    end
  end
end
