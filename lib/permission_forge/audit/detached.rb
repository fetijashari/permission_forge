# frozen_string_literal: true

module PermissionForge
  module Audit
    # Records an event that must outlive the transaction it was noticed in:
    # a failed sign-in, a refused change. Those are evidence of something
    # that did NOT happen, so a rollback of whatever the caller had open must
    # not take them with it.
    #
    #   Audit::Detached.record('admin.lock_refused', record: set)
    #
    # No transaction open (OpenTransaction): written at once, like
    # Audit.record. Inside one: written once that transaction has ended,
    # committed or rolled back (a savepoint that rolls back hands it to the
    # transaction around it). Who, where, the request and the reason are
    # taken at the moment of the call.
    #
    # @api private
    module Detached
      class << self
        # @param event [String] an admin, change or system event of the catalogue
        # @param payload [Hash] see Audit::Recorder
        # @return [AuditEvent, nil] the stored event; nil when it was deferred
        #   or auditing is off
        def record(event, **payload)
          transaction = OpenTransaction.current(PermissionForge::AuditEvent)
          return Audit.record(event, **payload) unless transaction

          defer(transaction, event, pinned(payload))
          nil
        end

        private

        # Who, where and the tenant of the moment of the call: a tenant
        # switched (or lost) before the transaction ends does not move it.
        def pinned(payload)
          { actor: Actor.current, source: Source.current, ambient_tenant_id: PermissionForge.ambient_tenant_id }.merge(payload)
        end

        # OpenTransaction#after_end: once, when the outermost transaction has
        # ended either way (a savepoint that rolls back hands it on).
        def defer(transaction, event, payload)
          context = Context.current
          transaction.after_end { Context.with(**context) { write_later(event, payload) } }
        end

        # Runs from Rails' commit or rollback of the caller's transaction:
        # raising there would replace the caller's own exception, or fail a
        # transaction that has already committed. Nothing can be kept from
        # happening any more, so a failure is reported (or logged) and never
        # raised, whatever the strategy.
        def write_later(event, payload)
          Audit.record(event, **payload)
        rescue StandardError => e
          strategy = PermissionForge.configuration.audit_hook_failure_strategy
          Failure.handle(e, strategy: strategy == :raise ? :report : strategy, operation: :store, event: event)
        end
      end
    end
  end
end
