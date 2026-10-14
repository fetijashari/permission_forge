# frozen_string_literal: true

module PermissionForge
  module Cache
    # Makes a cache failure visible without raising: an invalidation the store
    # did not confirm, an entry that could not be removed, or an error inside
    # an after_commit invalidation. Raising there would make Rails skip the
    # commit callbacks of the remaining records, so the failure is
    #
    #   - logged at error level,
    #   - published as the `cache_failure.permission_forge` notification, and
    #   - handed to `config.on_cache_failure`.
    #
    # A subscriber or a hook that raises is logged and does not stop the other.
    #
    # What a failure means: a cached permission hash that should be gone may
    # still be in the store, and stays there until `cache_ttl`.
    #
    # Code that has to say whether an invalidation went through asks here
    # (.none?), not the method it called: a host app overrides
    # User#invalidate_permissions, and what such an override returns is its
    # own business.
    #
    # @api private
    module Failure
      # The failures reported inside a Failure.collect block.
      #
      # @api private
      class Collected
        # Payloads kept per collect. A collect abandoned in an Enumerator
        # stays open (the end of a run keeps the open collects), so what it
        # keeps is bounded; past the bound it confirms nobody (fails closed).
        MAX_PAYLOADS = 1_000

        def initialize
          @payloads = []
          @overflowed = false
        end

        def <<(payload)
          @payloads.size < MAX_PAYLOADS ? @payloads << payload : @overflowed = true
          self
        end

        # @return [Array<Hash>] the payloads, in order
        def to_a
          @payloads.dup
        end

        # Those of `user_ids` that no failure was about — none when one was
        # about nobody in particular (it may be about any of them).
        #
        # @param user_ids [Array]
        # @return [Array]
        def confirmed(user_ids)
          return [] if @overflowed || failed_user_ids.include?(nil)

          user_ids.reject { |user_id| failed_user_ids.include?(user_id.to_s) }
        end

        private

        # As Strings (a key may come back as either); nil for a failure
        # about nobody in particular.
        def failed_user_ids
          @payloads.map { |payload| payload[:user_id]&.to_s }
        end
      end

      EVENT = 'cache_failure.permission_forge'
      # ExecutionState slots: how many failures were reported on this thread
      # (fiber under Rails' fiber isolation), and the open collect blocks.
      COUNT_KEY = :pf_cache_failures
      COLLECT_KEY = :pf_cache_failure_collectors
      # Open collects kept per thread: more can only be abandoned ones (an
      # Enumerator paused inside a collect), so the oldest go first.
      MAX_OPEN_COLLECTS = 64

      class << self
        # Runs the block and says whether it got through without a failure
        # being reported on this thread: every invalidation made inside it was
        # confirmed by the store.
        #
        # @return [Boolean]
        def none?
          before = count
          yield
          count == before
        end

        # Runs the block and returns what was reported on this thread inside it.
        # The open collects are one list per thread (fiber under fiber
        # isolation): each one takes out its own Collected when it ends, so
        # collects that interleave (one paused in an Enumerator) never take
        # each other's.
        #
        # @return [Collected]
        def collect
          collected = Collected.new
          open = ExecutionState.fetch(COLLECT_KEY) { [] }
          open.shift while open.size >= MAX_OPEN_COLLECTS
          open.push(collected)
          yield
          collected
        ensure
          ExecutionState[COLLECT_KEY]&.delete_if { |open| open.equal?(collected) }
        end

        # @param operation [Symbol] :invalidate, :discard or :after_commit
        # @param details [Hash] user_id: whose cached permissions are concerned,
        #   keys: cache keys that may still hold an entry, error: what the store
        #   (or the callback) raised — and anything else worth knowing
        #   (record:, attempts:)
        # @return [void]
        def report(operation:, **details)
          payload = { operation: operation, user_id: nil, keys: [], error: nil, **details }

          ExecutionState[COUNT_KEY] = count + 1
          ExecutionState[COLLECT_KEY]&.each { |collected| collected << payload }
          log(payload)
          notify(payload)
          call_hook(payload)
        end

        private

        def count
          ExecutionState[COUNT_KEY] || 0
        end

        def log(payload)
          return unless defined?(Rails) && Rails.logger

          Rails.logger.error("[PermissionForge] #{message(payload)} — cached permissions may be out of date until cache_ttl")
        end

        def message(payload)
          cause = payload[:error]
          parts = ["cache #{payload[:operation]} failed"]
          parts << "for user #{payload[:user_id]}" if payload[:user_id]
          parts << "(keys: #{payload[:keys].join(', ')})" if payload[:keys].any?
          parts << "— #{cause.class}: #{cause.message}" if cause
          parts.join(' ')
        end

        # A subscriber that raises would abort the commit callbacks this is
        # reported from, like a hook that raises.
        def notify(payload)
          ActiveSupport::Notifications.instrument(EVENT, payload)
        rescue StandardError => e
          log_error('subscriber', e)
        end

        def call_hook(payload)
          hook = PermissionForge.configuration.on_cache_failure
          return unless hook

          hook.call(**payload)
        rescue StandardError => e
          log_error('on_cache_failure hook', e)
        end

        def log_error(source, error)
          return unless defined?(Rails) && Rails.logger

          Rails.logger.error("[PermissionForge] #{EVENT} #{source} error: #{error.class}: #{error.message}")
        end
      end
    end
  end
end
