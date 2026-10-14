# frozen_string_literal: true

module PermissionForge
  # The one place the gem keeps state for the code running right now: a
  # flag set inside a block, the record being read, the build in progress.
  # Nothing else in lib/ or app/ touches `Thread.current`, `Fiber[]`,
  # ActiveSupport::IsolatedExecutionState or a CurrentAttributes class
  # (test/permission_forge/execution_state_test.rb fails when something
  # does; its ALLOWED list names the exceptions and why).
  #
  # Every slot is listed in KEYS with what it holds, where it is kept and
  # what the end of an executor run (a request, a job) does to it.
  #
  # Where (`scope`):
  #
  #   - :fiber — the running fiber, whatever Rails' isolation level says
  #     (Thread#[], which is fiber-local). For every slot whose value,
  #     seen by code it was not set for, would widen access (a scope
  #     suspended, a mask lifted, a re-entrant build answered with {}) or
  #     drop audit events (an emission or a read in progress): another
  #     fiber of the thread — an Enumerator iterated with #next, a
  #     streaming template — never sees it, and a fiber left paused inside
  #     the block takes it with it.
  #   - :execution — ActiveSupport::IsolatedExecutionState: per thread
  #     under Rails' `:thread` isolation (the fibers of the thread share
  #     it, as they share ActiveRecord's connection and CurrentAttributes),
  #     per fiber under `:fiber`. For state that has to be seen wherever
  #     the request's code runs: the audit context, the open invalidation
  #     batch of the connection, and the cache failures (a failure reported
  #     in an Enumerator's fiber must still count for the Failure.none?
  #     around it).
  #
  # At the end of a run (`at_run_end`):
  #
  #   - :clean — what the run added is removed, and nothing else: a slot
  #     that was empty when the run started is emptied, a collection that
  #     was there loses the entries the run added, and a slot that held a
  #     value is left alone. A request or job run starts empty, so there
  #     the slot is emptied, and nothing a request left set reaches the
  #     next one on the thread. Nothing is ever written back: a run may
  #     complete after the block it started in has ended
  #     (ActionDispatch::Executor completes it when the server closes the
  #     body, after the middlewares above it returned), and writing the
  #     block's value back then would leave it set for good. A block that
  #     wraps the whole run (a console or rake block around an inline job)
  #     keeps its value because it is still there.
  #   - :keep — outlives runs: a counter only ever compared before and
  #     after one call, or a slot whose block puts back what it found and
  #     which, emptied in the middle of the block, would fail open.
  #
  # A run that completes inside a block that started during the run — a
  # `run!(reset: true)` completing an outer run (ActionDispatch::Executor
  # does that for a run left open) — empties that block's slot for the
  # rest of the block: it fails closed (scoping applies again).
  #
  # @api private
  module ExecutionState
    # One slot: its name, where it is kept (:fiber or :execution), what the
    # end of an executor run does to it (:clean or :keep) and what it holds.
    Key = Data.define(:name, :scope, :at_run_end, :holds)

    SCOPES = %i[fiber execution].freeze
    AT_RUN_END = %i[clean keep].freeze

    KEYS = [
      Key.new(:pf_skip_auto_scope, :fiber, :clean,
              'true inside PermissionForge.without_permission_scope (and the internal builds): Level 1 auto-scoping ' \
              'and Level 2 detection are suspended. Fiber: seen elsewhere it would lift scoping there'),
      Key.new(:pf_internal_scope_suspension, :fiber, :clean,
              'true while the gem suspends Level 1 for its own queries (AutoPermissionScoping.internally_suspended: ' \
              'find_by / permission_scoped bodies, invalidation holders, cache clears, audit lookups): not reported as ' \
              'a scope_suspended bypass, and nobody signed in gets no find_by bypass. Same scope as pf_skip_auto_scope ' \
              '(host_suspended? reads both). Fiber: seen elsewhere it would hide a bypass from the audit log'),
      Key.new(:pf_in_auto_scope_hook, :fiber, :clean,
              'true while the Level 1 default scope builds the rules: a query made meanwhile (current_user_resolver, a ' \
              'permissions rebuild) runs unscoped instead of recursing. Fiber: seen elsewhere every query runs unscoped'),
      Key.new(:pf_building_permission_keys, :fiber, :clean,
              'Hash of permission cache key => the read-through build (or request-context resolution) in progress; a ' \
              'read of a key being built gets the reentrant {}. Fiber: seen elsewhere a read gets {} (rules off)'),
      Key.new(:pf_raw_store_columns, :fiber, :clean,
              'Hash (by identity) of record => the store column a store accessor is writing. Fiber: seen elsewhere ' \
              'the column reads unmasked'),
      Key.new(:pf_validating_records, :fiber, :clean,
              'Set (by identity) of the records whose validators are running (MaskedAttributes::ValidationReads). ' \
              'Fiber: seen elsewhere a validation read there would read stored values'),
      Key.new(:pf_validator_windows, :fiber, :clean,
              'Set (by identity) of the records a Rails EachValidator is judging: the attribute it read for the ' \
              'validation stays readable as stored until it is done (numericality reads it twice). Fiber: seen ' \
              'elsewhere that attribute reads unmasked'),
      Key.new(:pf_validation_reads, :fiber, :clean,
              'Hash (by identity) of record => the attribute a validator is reading, which reads as stored. Fiber: ' \
              'seen elsewhere that column reads unmasked'),
      Key.new(:pf_unmasked_virtual_records, :fiber, :clean,
              'Set (by identity) of the records inside pf_without_virtual_masking. Fiber: seen elsewhere the virtual ' \
              'readers read unmasked'),
      Key.new(:pf_audit_emitting, :fiber, :clean,
              'true while a runtime audit event is built, stored or published (re-entrancy guard). Fiber: seen ' \
              'elsewhere no runtime event is emitted there'),
      Key.new(:pf_audit_field_access, :fiber, :clean,
              'the Audit::FieldAccess::Frame of the record read in progress. Fiber: seen elsewhere its decisions go ' \
              'into a frame that is not theirs'),
      Key.new(:pf_inspecting, :fiber, :clean,
              'true while inspect / pretty_print read a record: no field.access decision. Fiber: seen elsewhere ' \
              'field reads go unrecorded'),
      Key.new(:pf_open_invalidation_batch, :execution, :clean,
              'the InvalidationBatch the next permission record written on its connection joins. Execution, like the ' \
              'connection: losing or sharing a batch costs repeated invalidations, never a missed one'),
      Key.new(:pf_cache_failure_collectors, :execution, :keep,
              'stack of Cache::Failure::Collected, one per Cache::Failure.collect block. Execution: a failure ' \
              'reported in a fiber of the block is collected. Kept at the end of a run: each collect removes its ' \
              'own entry by identity, and emptying the stack inside a block would lose its failure (fails open)'),
      Key.new(:pf_cache_failures, :execution, :keep,
              'Integer count of the cache failures reported (Cache::Failure.none? compares it before and after). ' \
              'Execution: a failure in a fiber of the block counts; never reset, so a none? around a run sees one in it'),
      Key.new(:pf_store_errors, :execution, :keep,
              'Array of the errors a cache store handed its error handler during the store call in progress ' \
              '(Cache::HandledErrors.during, .written). Execution: another fiber\'s error seen here counts against the call ' \
              '(it is tried again). Kept at the end of a run: the block puts back what it found, and emptying the ' \
              'slot inside the call would lose the error (a failed write taken for done)'),
      Key.new(:pf_audit_context, :execution, :clean,
              'the frozen Hash of the Audit::Context slots (actor, source, request id, IP, reason, correlation id)'),
      Key.new(:pf_audit_transaction_correlation, :execution, :clean,
              '[transaction, id] of the correlation id minted for the outermost open transaction'),
      Key.new(:pf_audit_runtime_once, :execution, :clean,
              'Hash of the runtime audit events published once per request (Audit::Runtime.once?)')
    ].to_h { |key| [key.name, key] }.freeze

    CLEANED = KEYS.values.select { |key| key.at_run_end == :clean }.map(&:name).freeze

    # The :fiber store: Thread#[] is fiber-local.
    module FiberStorage
      class << self
        def [](name)
          Thread.current[name]
        end

        def []=(name, value)
          Thread.current[name] = value
        end

        # Ruby drops a fiber-local set to nil.
        def delete(name)
          locals = Thread.current
          value = locals[name]
          locals[name] = nil unless value.nil?
          value
        end
      end
    end

    STORAGE = KEYS.transform_values { |key| key.scope == :fiber ? FiberStorage : ActiveSupport::IsolatedExecutionState }.freeze

    # The :clean slots by scope: what the start and the end of a run walk.
    CLEANED_FIBER = CLEANED.select { |name| KEYS[name].scope == :fiber }.freeze
    CLEANED_EXECUTION = (CLEANED - CLEANED_FIBER).freeze

    # The executor hook (Rails.application.executor.register_hook): notes
    # what the :clean slots hold when a run starts, and removes what the run
    # added when it completes.
    module RunHook
      # The fiber and the execution context the run started on, and what the
      # :clean slots held then (ExecutionState.snapshot; nil for nothing).
      Snapshot = Data.define(:fiber, :context, :values)

      class << self
        # @return [Snapshot]
        def run
          Snapshot.new(Fiber.current, ActiveSupport::IsolatedExecutionState.context, ExecutionState.snapshot)
        end

        # Only where the run started: its fiber (:fiber slots) or its
        # execution context (:execution slots).
        #
        # @param snapshot [Snapshot]
        # @return [void]
        def complete(snapshot)
          ExecutionState.run_completed(snapshot.values, fiber: snapshot.fiber.equal?(Fiber.current),
                                                        execution: snapshot.context.equal?(ActiveSupport::IsolatedExecutionState.context))
        end
      end
    end

    class << self
      # @param name [Symbol] a key of KEYS
      # @return [Object, nil]
      def [](name)
        storage(name)[name]
      end

      # @param name [Symbol] a key of KEYS
      # @return [Object] the value
      def []=(name, value)
        storage(name)[name] = value
      end

      # The slot's value; when it holds nothing, the block's value, stored.
      #
      #   ExecutionState.fetch(:pf_unmasked_virtual_records) { Set.new.compare_by_identity }
      #
      # @param name [Symbol] a key of KEYS
      # @return [Object]
      def fetch(name)
        value = self[name]
        value.nil? ? (self[name] = yield) : value
      end

      # @param name [Symbol] a key of KEYS
      # @return [Object, nil] what the slot held
      def delete(name)
        store = storage(name)
        store.delete(name)
      end

      # Sets the slot for the block and puts back what it held when the
      # block ends, however it ends (a slot that held nil is emptied).
      #
      # @param name [Symbol] a key of KEYS
      # @return the block's value
      def with(name, value)
        store = storage(name)
        previous = store[name]
        store[name] = value
        begin
          yield
        ensure
          previous.nil? ? store.delete(name) : store[name] = previous
        end
      end

      # Empties every slot of this fiber and execution context: tests.
      #
      # @return [void]
      def reset!
        KEYS.each_key { |name| delete(name) }
      end

      # Registers RunHook with the application's executor (every request and
      # job). Called once by Audit.install!.
      #
      # @param app [Rails::Application]
      # @return [void]
      def install!(app)
        app.executor.register_hook(RunHook)
      end

      # What the :clean slots hold now (RunHook): nil when they are all
      # empty (a request or a job), else name => [value, copy of its entries
      # when it is a collection changed in place].
      #
      # @return [Hash{Symbol => Array(Object, Object)}, nil]
      def snapshot
        values = nil
        locals = Thread.current
        CLEANED_FIBER.each { |name| values = noted(values, name, locals[name]) }
        CLEANED_EXECUTION.each { |name| values = noted(values, name, ActiveSupport::IsolatedExecutionState[name]) }
        values
      end

      # The end of an executor run (RunHook): removes from the :clean slots of
      # the scopes the run ends in what the run added, and never writes a
      # value. A slot empty at the start (`values` from #snapshot) is
      # emptied; from a collection there at the start, the entries the run
      # added are dropped; any other slot is left as it is.
      #
      # @param values [Hash, nil] from #snapshot
      # @return [void]
      def run_completed(values, fiber:, execution:)
        clean_all(CLEANED_FIBER, FiberStorage, values) if fiber
        clean_all(CLEANED_EXECUTION, ActiveSupport::IsolatedExecutionState, values) if execution
      end

      private

      def noted(values, name, value)
        return values if value.nil?

        (values || {}).merge!(name => [value, collection?(value) ? value.dup : nil])
      end

      def clean_all(names, store, values)
        return names.each { |name| store.delete(name) } unless values

        names.each { |name| (before = values[name]) ? clean(store, name, before) : store.delete(name) }
      end

      # A slot that held `value` when the run started: only a collection
      # still in it loses what the run added.
      def clean(store, name, before)
        value, entries = before
        return unless entries

        current = store[name]
        drop_added(current, entries) if current.equal?(value)
      end

      # Drops the entries of `collection` that `before` (its copy from the
      # start of the run) does not have.
      def drop_added(collection, before)
        case collection
        when Hash then collection.select! { |key, _| before.key?(key) }
        when Set then collection.select! { |entry| before.include?(entry) }
        else collection.select! { |entry| before.any? { |kept| kept.equal?(entry) } }
        end
      end

      def storage(name)
        STORAGE.fetch(name) do
          raise ArgumentError, "unknown execution state key #{name.inspect} (PermissionForge::ExecutionState::KEYS)"
        end
      end

      # A collection changed in place (a frozen one is replaced, never changed).
      def collection?(value)
        (value.is_a?(Hash) || value.is_a?(Set) || value.is_a?(Array)) && !value.frozen?
      end
    end
  end
end
