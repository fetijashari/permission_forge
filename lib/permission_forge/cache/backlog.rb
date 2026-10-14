# frozen_string_literal: true

module PermissionForge
  module Cache
    # The invalidations this process could not get the store to confirm, kept
    # so they can be made when the store answers again. An entry is listed by
    # its stamp key: one per user (PermissionCacheAccessor), one for the
    # managed-actions index (ControllerActions::ManagedIndex).
    #
    # Without it, an entry that should have been removed while the store was
    # unreachable is a cache hit again as soon as the store is back, and
    # stays one until cache_ttl. With it:
    #
    #   - a user listed here is not served from the store by this process:
    #     the hash is rebuilt (PermissionCacheAccessor#pf_read_shared_permissions);
    #     neither is the managed-actions index while it is listed;
    #   - the listed invalidations are tried again after the next one the
    #     store confirms, and before a hash is read from the store while the
    #     list is not empty (Invalidation.retry_owed).
    #
    # This is extra effort on top of the failure report, not a guarantee. The
    # list lives in this process: another process serves the entry as before,
    # a restart forgets the list, and it holds LIMIT entries — the one owed
    # longest is dropped for a new one. An edit to a set whose holders the
    # store fails to invalidate (HolderInvalidation, during an outage) owes
    # one entry per holder: past LIMIT holders only the last LIMIT are kept.
    # For all of those cache_ttl remains the backstop, and every failure was
    # reported when it happened.
    #
    # A pass over the list must not turn an outage — or the recovery from
    # one — into a delay for one request: it tries PER_PASS entries at most
    # (the next confirmed invalidation or store read goes on with the rest),
    # it stops after GIVE_UP_AFTER failed tries, and after a failed try the
    # next pass waits PAUSE seconds. A try that failed moves to the end of the
    # list, so an entry whose key keeps failing cannot hold up the others.
    #
    # @api private
    class Backlog
      LIMIT = 500
      PER_PASS = 25
      GIVE_UP_AFTER = 3
      PAUSE = 5

      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # @param clock [#call] seconds, monotonic
      def initialize(clock: MONOTONIC)
        @clock = clock
        @entries = {}
        @mutex = Mutex.new
        @pass = Mutex.new
        @paused_until = nil
      end

      # @return [Boolean] lock-free, for the path of every permission read
      def empty?
        @entries.empty?
      end

      # @param stamp_key [String] e.g. "user_1_invalidation"
      # @return [Boolean]
      def include?(stamp_key)
        @mutex.synchronize { @entries.key?(stamp_key) }
      end

      # @param user_id [Object, nil] whose invalidation is owed (for the
      #   report; nil for the managed-actions index)
      # @param stamp_key [String] where its invalidation stamp lives: what the
      #   entry is listed by
      # @param keys [Array<String>] the cache keys that may still hold an entry
      # @return [Boolean] whether this is news: false when the entry was listed
      #   with all of these keys already
      def add(user_id:, stamp_key:, keys:)
        @mutex.synchronize do
          known = @entries.delete(stamp_key)
          keys |= known[:keys] if known
          @entries[stamp_key] = { user_id: user_id, stamp_key: stamp_key, keys: keys }.freeze
          @entries.shift while @entries.size > LIMIT
          known.nil? || keys.size > known[:keys].size
        end
      end

      # One pass over the list, unless one is running or the last one failed
      # less than PAUSE seconds ago.
      #
      # @yieldparam entry [Hash] user_id:, stamp_key:, keys:
      # @yieldreturn [Boolean] whether the store confirmed the invalidation
      # @return [void]
      def try_again(&)
        return if paused? || !@pass.try_lock

        begin
          pause if pass(&).positive?
        ensure
          @pass.unlock
        end
      end

      # @return [void]
      def clear
        @mutex.synchronize { @entries.clear }
        @paused_until = nil
      end

      private

      # @return [Integer] the tries that failed
      def pass
        failures = 0
        @mutex.synchronize { @entries.values.first(PER_PASS) }.each do |entry|
          break if failures >= GIVE_UP_AFTER

          confirmed = yield(entry)
          failures += 1 unless confirmed
          settle(entry, confirmed)
        end
        failures
      end

      # Takes a confirmed entry off the list and moves a failed one to its
      # end — unless a new failure of the same entry has replaced it meanwhile.
      def settle(entry, confirmed)
        stamp_key = entry[:stamp_key]
        @mutex.synchronize do
          next unless @entries[stamp_key].equal?(entry)

          @entries.delete(stamp_key)
          @entries[stamp_key] = entry unless confirmed
        end
      end

      def paused?
        paused_until = @paused_until
        !paused_until.nil? && @clock.call < paused_until
      end

      def pause
        @paused_until = @clock.call + PAUSE
      end
    end
  end
end
