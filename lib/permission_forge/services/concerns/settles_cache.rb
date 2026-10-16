# frozen_string_literal: true

module PermissionForge
  module Services
    module Concerns
      # For an operation whose summary event is written in its transaction,
      # before its cache work (erasure.performed, consent.withdrawn record
      # `cache_confirmed: nil`): one `cache.settled` event, on the
      # operation's correlation id, says what the cache store answered once
      # the work ran.
      #
      # Outside a transaction that is the outcome the operation just
      # measured. Inside a caller's one (Cache::Report#deferred?) the work is
      # only done for everybody at its commit: it runs again there, measured,
      # and the event is written then, in the context of the operation
      # (OpenTransaction#after_commit: never after a rollback). The work
      # always runs, also with auditing off; a failure there is reported,
      # never raised out of the commit, and a store failure is what the event
      # records (`cache_confirmed: false`).
      #
      # @api private
      module SettlesCache
        EVENT = 'cache.settled'

        private

        # @param operation [String] the operation's name in the event's data ('erasure')
        # @param subject [Object] the person whose cached permissions it cleared
        # @param report [Cache::Report] the operation's measured report
        # @yield the cache work, run again after a caller's commit
        def settle_cache(operation, subject, report, &work)
          transaction = PermissionForge::OpenTransaction.current if report.deferred?
          return record_settled(operation, subject, report.outcome) unless transaction

          context = PermissionForge::Audit::Context.current
          transaction.after_commit do
            PermissionForge::Audit::Context.with(**context) do
              record_settled(operation, subject, PermissionForge::Cache::Report.of(&work))
            end
          rescue StandardError => e
            PermissionForge::Cache::Failure.report(operation: :invalidate, user_id: subject.id, error: e)
          end
        end

        # Written after the operation's transaction: like Audit::Detached, a
        # failure to store it is reported (or logged), never raised — the
        # operation has happened.
        def record_settled(operation, subject, outcome)
          PermissionForge::Audit.record(EVENT, subject_user_id: subject.id,
                                               data: { 'operation' => operation, **outcome.event_data })
        rescue StandardError => e
          strategy = PermissionForge.configuration.audit_hook_failure_strategy
          PermissionForge::Audit::Failure.handle(e, strategy: strategy == :raise ? :report : strategy, operation: :store, event: EVENT)
        end
      end
    end
  end
end
