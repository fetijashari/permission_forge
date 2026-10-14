# frozen_string_literal: true

module PermissionForge
  module Cache
    # One invalidation of a user's cached permission hashes — or of the
    # managed-actions index (ControllerActions::ManagedIndex): leaves a fresh
    # stamp, then removes the keys — and checks what the store answers.
    #
    # The stamp is written BEFORE the keys are removed. A rebuild that read its
    # rows before the commit is only dangerous when it stores its hash after
    # the removal; it re-reads the stamp after storing, so with this order the
    # new stamp is already there for it to see. Removing first would leave a
    # gap: remove, the stale hash is stored, the rebuild sees the old stamp,
    # and only then is the new stamp written — nothing would notice. (A rebuild
    # that stores before the removal loses its entry to it; either way no
    # pre-commit hash survives.) The keys are removed even when the stamp could
    # not be written.
    #
    # A store that is unreachable does not raise: it answers false or nil. So every
    # answer is checked, and an invalidation the store did not confirm is tried
    # again, ATTEMPTS times in all. When it still fails it is reported
    # (Cache::Failure) and not raised: the entry may then outlive the change
    # until cache_ttl, and somebody has to know.
    #
    # A store that is down fails every call, and each one may wait for a
    # timeout. After a failed invalidation the next ones therefore make a
    # single attempt for RETRY_PAUSE seconds, which keeps a commit that
    # invalidates many users from waiting three times as long for nothing.
    #
    # An invalidation that failed for good is still owed: it is put on the
    # process's Backlog and made when the store answers again.
    #
    # @api private
    class Invalidation
      ATTEMPTS = 3
      RETRY_PAUSE = 5

      class << self
        def call(...) = new(...).call

        # @return [Boolean] whether a recent invalidation failed for good
        def store_failing?
          until_time = @failing_until
          !until_time.nil? && now < until_time
        end

        def store_failed!
          @failing_until = now + RETRY_PAUSE
        end

        def store_answered!
          @failing_until = nil
        end

        # @return [Backlog] the invalidations this process still owes the store
        def backlog
          @backlog ||= Backlog.new
        end

        # Notes an invalidation the store did not confirm, to be made later.
        #
        # @return [Boolean] false when exactly this was owed already
        def owe(user_id:, stamp_key:, keys:)
          backlog.add(user_id: user_id, stamp_key: stamp_key, keys: keys)
        end

        # Whether an invalidation is still owed, after one more try to make
        # the owed ones. Costs nothing while nothing is owed.
        #
        # @param stamp_key [String] the stamp key of the invalidation (one per
        #   user, one for the managed-actions index)
        # @return [Boolean]
        def owed?(stamp_key)
          owed = backlog
          return false if owed.empty?

          retry_owed
          owed.include?(stamp_key)
        end

        # Tries the owed invalidations once each. Not while the store has just
        # failed one: an outage must not add a failing call to every request.
        # And not from inside an open database transaction: a store that
        # shares the connection (Solid Cache in the application's database)
        # would take the removals back if the transaction rolled back.
        #
        # @return [void]
        def retry_owed
          owed = backlog
          return if owed.empty? || store_failing? || PermissionForge::OpenTransaction.current

          owed.try_again { |entry| new(**entry).try_again }
        end

        # For tests, and for a cache store that has been replaced: what was
        # owed to the old one is not owed to the new one.
        def reset!
          store_answered!
          backlog.clear
        end

        private

        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # @param user_id [Object, nil] whose hashes are invalidated (for the
      #   report; nil for an entry that belongs to no user)
      # @param stamp_key [String] where the user's invalidation stamp lives
      # @param keys [Array<String>] the cache keys to remove
      def initialize(user_id:, stamp_key:, keys:, cache: PermissionForge.cache)
        @user_id = user_id
        @stamp_key = stamp_key
        @keys = keys
        @cache = cache
        @error = nil
      end

      # @return [Boolean] whether the store confirmed the stamp and every removal
      def call
        attempts = self.class.store_failing? ? 1 : ATTEMPTS
        confirmed = attempts.times.any? { attempt }
        confirmed ? succeeded : failed(attempts)
        confirmed
      end

      # One more try at an invalidation that failed for good. Without the
      # stamp nothing is removed this time: every key was tried when it failed.
      #
      # @return [Boolean] whether the store confirmed the stamp and every removal
      def try_again
        stamp && @keys.all? { |key| answered? { @cache.expunge(key) } }
      end

      private

      def attempt
        stamped = stamp
        # every key is tried, whatever happened to the stamp and to the keys before it
        removed = @keys.map { |key| answered? { remove(key, confirm: stamped) } }
        stamped && removed.all?
      end

      def stamp
        answered? { @cache.write(@stamp_key, SecureRandom.hex(8), ttl: PermissionForge.configuration.cache_ttl) }
      end

      # Without the stamp the attempt has failed already: the key is deleted
      # all the same, but not paid for a second time to confirm it.
      def remove(key, confirm:)
        return @cache.expunge(key) if confirm

        @cache.delete(key)
        false
      end

      def answered?
        yield
      rescue StandardError => e
        @error = e
        false
      end

      # The store answers: what is owed from before can be made now.
      def succeeded
        self.class.store_answered!
        self.class.retry_owed
      end

      def failed(attempts)
        invalidation = self.class
        invalidation.store_failed!
        invalidation.owe(user_id: @user_id, stamp_key: @stamp_key, keys: @keys)
        Failure.report(operation: :invalidate, user_id: @user_id, keys: @keys, error: @error, attempts: attempts)
      end
    end
  end
end
