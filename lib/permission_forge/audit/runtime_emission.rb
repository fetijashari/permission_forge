# frozen_string_literal: true

module PermissionForge
  module Audit
    # How Audit.instrument emits a runtime (access) event once it knows the
    # event is stored or heard. Extended into Audit; uses its #write, #notify
    # and #listening?.
    #
    # Published at once — the decision has been made, whatever becomes of the
    # transaction it was made in — never after a commit. Stored at once, or,
    # inside an open transaction, once the outermost transaction has ended,
    # committed or rolled back (a denial inside a transaction the denial
    # itself rolls back is still recorded); the notification then says
    # `stored: false, deferred: true`.
    #
    # Re-entrancy: nothing is done while this thread (fiber) is already
    # building, storing or publishing a runtime event (#emitting?). A payload
    # or a subscriber that reads a masked attribute or runs a permission
    # check gets its answer, but publishes no event about it — and cannot
    # loop.
    #
    # @api private
    module RuntimeEmission
      # Set while this fiber builds, stores or publishes a runtime event — a
      # fiber-local ExecutionState slot: the emission runs in the fiber that
      # started it.
      EMITTING_KEY = :pf_audit_emitting

      # @return [Boolean] whether this fiber is building, storing or
      #   publishing a runtime event
      def emitting?
        ExecutionState[EMITTING_KEY] == true
      end

      # Hands { data:, objects: } to the gem's light subscribers
      # (Gate#direct_listeners) with the re-entrancy guard, building no event.
      # For a caller that has the payload at hand (Audit::FieldAccess).
      #
      # @return [nil]
      def emit_light(entry, listeners, light)
        return if emitting?

        emitting { deliver_light(entry, listeners, light) }
        nil
      end

      # One field decision handed to the light subscribers (the legacy
      # on_field_filtered hook) as it is made (Audit::FieldAccess::Direct).
      #
      # @return [nil]
      def emit_decision(listeners, resource_name, field_name, action, user)
        return if emitting?

        emitting do
          listeners.each { |listener| listener.deliver_decision(resource_name, field_name, action, user) }
        end
        nil
      end

      private

      # The legacy hooks are the only listeners and nothing is stored
      # (Gate#direct_listeners): they get { data:, objects: } straight away —
      # no Recorder, no actor, no notification.
      #
      # @return [nil]
      def instrument_light(entry, listeners, payload)
        return if emitting?

        emitting do
          payload = runtime_payload(entry, payload) { yield if block_given? }
          unless payload.equal?(FAILED)
            light = { event: entry.name, data: payload[:data] || {}, objects: payload[:objects] || Recorder::NO_OBJECTS }
            deliver_light(entry, listeners, light)
          end
        end
        nil
      end

      def deliver_light(entry, listeners, light)
        listeners.each { |listener| listener.deliver_light(entry.notification, light) }
      rescue StandardError => e
        Failure.handle(e, strategy: configuration.audit_hook_failure_strategy, operation: :publish, event: entry.name)
      end

      # @return [AuditEvent, nil]
      def instrument_runtime(entry, payload, store:)
        return if emitting?

        emitting do
          payload = runtime_payload(entry, payload) { yield if block_given? }
          emit_runtime(Recorder.new(entry, payload), store: store) unless payload.equal?(FAILED)
        end
      end

      def emitting(&)
        ExecutionState.with(EMITTING_KEY, true, &)
      end

      # The caller's payload with the block's merged in, source 'runtime'
      # unless given. A block that raises follows audit_hook_failure_strategy.
      def runtime_payload(entry, payload)
        more = yield
        payload = payload.merge(more) if more
        payload.merge(source: payload[:source] || 'runtime')
      rescue StandardError => e
        Failure.handle(e, strategy: configuration.audit_hook_failure_strategy, operation: :build, event: entry.name)
        FAILED
      end

      def emit_runtime(recorder, store:)
        transaction = OpenTransaction.current(PermissionForge::AuditEvent) if store
        stored = write(recorder, store: store && transaction.nil?, strategy: configuration.audit_hook_failure_strategy,
                                 change: false)
        return if stored.equal?(FAILED)

        store_runtime_later(transaction, recorder) if transaction
        notify(recorder.entry, recorder.notification_payload(stored, deferred: !transaction.nil?)) if listening?(recorder.entry)
        stored
      end

      # OpenTransaction#after_end: once, when the outermost transaction has
      # ended either way (a savepoint that rolls back hands it on). It runs
      # from Rails' commit or rollback, where raising would replace the
      # caller's own exception: a failure is reported, never raised, whatever
      # the strategy (as Audit::Detached does).
      def store_runtime_later(transaction, recorder)
        transaction.after_end do
          strategy = configuration.audit_hook_failure_strategy
          emitting { write(recorder, store: true, strategy: strategy == :raise ? :report : strategy, change: false) }
        end
      end
    end
  end
end
