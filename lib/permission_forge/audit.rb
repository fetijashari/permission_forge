# frozen_string_literal: true

module PermissionForge
  # The one emitter of audit events.
  #
  #   PermissionForge::Audit.record('assignment.revoked', record: assignment, reason: 'left the team')
  #   PermissionForge::Audit.instrument('access.denied') { { data: { 'model' => 'Customer', 'id' => 42 } } }
  #
  # `record` stores a change, admin or system event (when auditing is on) and
  # publishes it as the "<event>.permission_forge" notification once the
  # transaction it was recorded in has committed. `instrument` publishes a
  # runtime (access) event and stores it only when its group is listed in
  # `config.audit_runtime_events`; when nobody subscribes and the group is not
  # stored it returns before building anything.
  #
  # Who, where and why come from the audit context (Audit::Context, set by
  # `PermissionForge.with_audit_actor`, `Audit::Context.with` and the
  # controllers), the record (Concerns::RecordsAuditEvents#audit_reference)
  # and the payload (Audit::Recorder lists the keys).
  #
  # What happens when an event cannot be built or stored:
  #   - `record` follows config.audit_change_failure_strategy. Under :raise
  #     (default) an EventNotRecordedError is raised — out of the change's
  #     callback, so the change rolls back — and the open transaction is made
  #     to fail at commit (OpenTransaction#before_commit), so a caller that
  #     rescues the error inside its own transaction cannot commit the change
  #     without its record. Under :report / :log the event is written in a
  #     savepoint (a failed INSERT must not abort the caller's transaction on
  #     PostgreSQL), the failure is reported and the change goes through.
  #   - `instrument` follows config.audit_hook_failure_strategy, always in a
  #     savepoint: a denial is never allowed to break the request that was
  #     denied.
  #
  # @api public
  module Audit
    # A change could not be recorded (audit_change_failure_strategy = :raise).
    # `cause` is what building or storing the event raised. Raised twice at
    # most: out of the change, and again at the commit of a transaction that
    # rescued it.
    #
    # @api public
    class EventNotRecordedError < StandardError
      # @return [String, nil] the name of the event that could not be written
      attr_reader :event

      def initialize(message = nil, event: nil, at_commit: false)
        @event = event
        super(message || default_message(event, at_commit))
      end

      private

      def default_message(event, at_commit)
        if at_commit
          "the transaction was rolled back at commit: the audit event #{event} of a change inside it could not be written"
        else
          "the audit event #{event} could not be written, so the change was not made"
        end
      end
    end

    # How long a missing table is believed before it is looked for again:
    # a worker that started before the migration records once it has run.
    MISSING_TABLE_RECHECK = 60

    TABLE_CHECK_MUTEX = Mutex.new
    FAILED = Object.new.freeze
    private_constant :FAILED

    @table_checks = {}
    @warned_tables = {}
    @missing_table_recheck = MISSING_TABLE_RECHECK

    extend RuntimeEmission

    class << self
      # Seconds a missing table is believed before it is looked for again.
      attr_accessor :missing_table_recheck

      # @param event [String] a name from the catalogue (not an access event)
      # @param payload [Hash] see Audit::Recorder
      # @return [AuditEvent, nil] the stored event; nil when auditing is off
      #   or the write failed under a non-raising audit_change_failure_strategy
      # @raise [EventCatalog::UnknownEventError, ArgumentError, EventNotRecordedError]
      def record(event, **payload)
        entry = EventCatalog.fetch(event)
        raise ArgumentError, "#{entry.name} is an access event: publish it with Audit.instrument" if entry.runtime?

        emit(Recorder.new(entry, payload), store: enabled?, strategy: configuration.audit_change_failure_strategy, change: true)
      end

      # @param event [String] an access event of the catalogue
      # @param payload [Hash] see Audit::Recorder; source defaults to 'runtime'
      # @yieldreturn [Hash] more payload, built only when the event is stored
      #   or someone listens — for hot paths:
      #     Audit.instrument('field.access') { { record: record, data: { 'hidden' => hidden } } }
      # @return [AuditEvent, nil] the stored event, when its group is stored
      #
      # Published at once, stored now or when the open transaction has ended
      # (committed or rolled back); nothing while this thread is already
      # emitting a runtime event. See Audit::RuntimeEmission.
      def instrument(event, **payload, &)
        entry = EventCatalog.fetch(event)
        raise ArgumentError, "#{entry.name} is a #{entry.category} event: store it with Audit.record" unless entry.runtime?

        light = Gate.for(entry.name).direct_listeners
        return instrument_light(entry, light, payload, &) if light

        storing, listening = runtime_plan(entry)
        return unless storing || listening

        instrument_runtime(entry, payload, store: storing, &)
      end

      # Whether instrumenting this event would do anything right now: its
      # group is stored, or someone listens — and this thread is not already
      # emitting one. For callers whose payload is expensive to gather.
      #
      # @param event [String] an access event of the catalogue
      # @return [Boolean]
      def instrument?(event)
        entry = EventCatalog.fetch(event)
        entry.runtime? && Gate.for(entry.name).open? && !emitting? &&
          ((configuration.store_runtime_group?(entry.runtime_group) && enabled?) || listening?(entry))
      end

      # Whether events are stored: config.audit_events, and under :auto
      # whether the table exists. A table that exists is remembered for the
      # process; one that does not is looked for again after
      # MISSING_TABLE_RECHECK seconds (reset! forgets at once).
      #
      # @param configuration [Configuration]
      # @return [Boolean]
      def enabled?(configuration = PermissionForge.configuration)
        case configuration.audit_events
        when true then true
        when false then false
        else table_available?
        end
      end

      # Gives every event inside the block one correlation id (an outer block's
      # id, else `id`, else a new one).
      #
      #   PermissionForge::Audit.correlate { change_set.apply! }
      #
      # @return the value of the block
      def correlate(id = nil, &)
        Context.with(correlation_id: Context[:correlation_id] || id || new_id, &)
      end

      # Logs the boot warning when :auto finds no table. Called by the engine
      # once the database is reachable.
      def verify_table!
        enabled? if configuration.audit_events == :auto
      end

      # Forgets the table check and empties the context of this thread (tests,
      # after a migration in the same process).
      def reset!
        TABLE_CHECK_MUTEX.synchronize do
          @table_checks = {}
          @warned_tables = {}
        end
        Context.reset!
        Runtime.reset!
      end

      # Installs the notification subscribers and the executor hook of the
      # gem's execution state (ExecutionState.install!): at the end of every
      # executor run (request, job) whatever the run added to the audit
      # context, to what runtime events remember for one request (Runtime)
      # and to every block-scoped slot is removed — a request or a job ends
      # with them empty. Called by the engine once configuration is final.
      def install!(app)
        Gate.install!
        Subscribers.install!(configuration)
        ExecutionState.install!(app)
      end

      # @return [String] a fresh id from `config.uuid_generator`
      # @api private
      def new_id
        configuration.uuid_generator.call
      end

      # @param entry [EventCatalog::Entry]
      # @return [Boolean] whether anyone subscribes to the event's notification
      def listening?(entry)
        ActiveSupport::Notifications.notifier.listening?(entry.notification)
      end

      private

      def configuration
        PermissionForge.configuration
      end

      # [whether the event is stored, whether anyone listens]. The cheap
      # answers first; the table is consulted only for a group that is stored.
      def runtime_plan(entry)
        return [false, false] unless Gate.for(entry.name).open?

        storing = configuration.store_runtime_group?(entry.runtime_group)
        listening = listening?(entry)
        return [false, false] unless storing || listening

        [storing && enabled?, listening]
      end

      def emit(recorder, store:, strategy:, change:)
        stored = write(recorder, store: store, strategy: strategy, change: change)
        return if stored.equal?(FAILED)

        publish(recorder, stored)
        stored
      end

      # Builds the event once and stores it, in a savepoint: a failed INSERT
      # aborts the transaction it ran in on PostgreSQL, and the caller's
      # transaction must stay usable — to go on under :report / :log, and to
      # fail at its commit under :raise rather than at its next statement.
      # Whatever fails here — resolving the actor, a payload that cannot be
      # read, the INSERT — follows `strategy`.
      #
      # @return [AuditEvent, nil, FAILED]
      def write(recorder, store:, strategy:, change:)
        recorder.attributes
        return nil unless store

        PermissionForge::AuditEvent.transaction(requires_new: true) { recorder.store! }
      rescue StandardError => e
        raise_not_recorded(recorder, e) if change && strategy == :raise

        Failure.handle(e, strategy: strategy, operation: :store, event: recorder.name)
        FAILED
      end

      # The change must not be committed: raise out of its callback, and make
      # the transaction it runs in fail at commit for a caller that rescues.
      def raise_not_recorded(recorder, error)
        OpenTransaction.current&.before_commit do
          raise EventNotRecordedError.new(event: recorder.name, at_commit: true), cause: error
        end
        raise EventNotRecordedError.new(event: recorder.name)
      end

      # After the open transaction commits (never after a rollback), else now.
      def publish(recorder, stored)
        return unless listening?(recorder.entry)

        payload = recorder.notification_payload(stored)
        transaction = OpenTransaction.current
        if transaction
          transaction.after_commit { notify(recorder.entry, payload) }
        else
          notify(recorder.entry, payload)
        end
      end

      def notify(entry, payload)
        ActiveSupport::Notifications.instrument(entry.notification, payload)
      rescue StandardError => e
        Failure.handle(e, strategy: configuration.audit_hook_failure_strategy, operation: :publish, event: entry.name)
      end

      # A table that was found is remembered without taking the lock. A
      # missing one is believed for MISSING_TABLE_RECHECK seconds; a database
      # that cannot be reached counts as no table and is asked again next time.
      def table_available?
        name = PermissionForge::AuditEvent.table_name
        return true if @table_checks[name] == true

        TABLE_CHECK_MUTEX.synchronize do
          cached = @table_checks[name]
          return true if cached == true
          return false if cached.is_a?(Numeric) && Process.clock_gettime(Process::CLOCK_MONOTONIC) - cached < missing_table_recheck

          check_table(name)
        end
      end

      # A database that does not answer or does not exist
      # (DatabaseReach::UNREACHABLE_ERRORS) is "unchecked": nothing is
      # recorded until it answers. Any other error of the check — a
      # configuration error included — raises out of Audit.record, so the
      # change it records rolls back.
      def check_table(name)
        cause = nil
        exists = PermissionForge::DatabaseReach.table_exists?(PermissionForge::AuditEvent,
                                                              errors: PermissionForge::DatabaseReach::UNREACHABLE_ERRORS) { |e| cause = e }
        if cause
          warn_unchecked_table(name, cause)
          return false
        end
        return @table_checks[name] = true if exists

        @table_checks[name] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        warn_missing_table(name) unless @warned_tables[name]
        @warned_tables[name] = true
        false
      end

      def warn_unchecked_table(name, cause)
        PermissionForge::Warnings.emit(:audit_table_unchecked, "cannot check for the audit table '#{name}' (#{cause.class}): " \
                                                               'no audit events are recorded until the database answers.',
                                       severity: :security)
      end

      def warn_missing_table(name)
        PermissionForge::Warnings.emit(:audit_table_missing, BootWarnings.missing_table(name), severity: :security)
      end
    end
  end
end
