# frozen_string_literal: true

module PermissionForge
  module Cache
    # Many invalidations at once: what Invalidation does for one — a fresh
    # stamp, then the keys, every answer checked, ATTEMPTS tries, what still
    # fails reported (Failure) and owed (Backlog) — with one multi-key call
    # per step (Base#write_many, Base#expunge_many) instead of one call per
    # key. On a store that sends them together (Redis, Solid Cache) a slice
    # of users costs two round trips instead of three to five per user.
    #
    # The order holds for every user: all the stamps of the call are written
    # before any key is removed, so each user's stamp is there before that
    # user's keys go (see Invalidation). The keys are removed even when the
    # stamps could not be written — then plainly deleted, not confirmed
    # (Invalidation#remove): that user has failed already, and on a store
    # that is down a confirmation is one more failing call per key. An
    # attempt only repeats the users the store did not confirm.
    #
    # Callers keep the size of one call bounded (HolderInvalidation::SLICE).
    #
    # @api private
    class BulkInvalidation
      def self.call(...) = new(...).call

      # The ids of the users whose invalidation the store did not confirm.
      # A call that raises as a whole is owed and reported user by user.
      #
      # @param targets [Array<Hash>] as for #initialize
      # @return [Array]
      def self.unconfirmed(targets)
        call(targets).map { |target| target[:user_id] }
      rescue StandardError => e
        targets.each do |target|
          Invalidation.owe(**target)
          Failure.report(operation: :invalidate, **target.slice(:user_id, :keys), error: e)
        end
        targets.map { |target| target[:user_id] }
      end

      # @param targets [Array<Hash>] one per user, the arguments of an
      #   Invalidation: user_id:, stamp_key:, keys:
      def initialize(targets, cache: PermissionForge.cache)
        @targets = targets
        @cache = cache
        @error = nil
      end

      # @return [Array<Hash>] the targets the store did not confirm (empty
      #   when it confirmed every one)
      def call
        attempts = Invalidation.store_failing? ? 1 : Invalidation::ATTEMPTS
        pending = @targets
        attempts.times do
          break if pending.empty?

          pending = attempt(pending)
        end
        failed(pending, attempts) if pending.any?
        # as Invalidation does user by user: once one is confirmed, the store
        # answers, and what is owed (the failures just now included) is tried
        succeeded if pending.size < @targets.size
        pending
      end

      private

      # @return [Array<Hash>] the targets still unconfirmed after this attempt
      def attempt(targets)
        stamped = answers { @cache.write_many(fresh_stamps(targets), ttl: PermissionForge.configuration.cache_ttl, &method(:keep_error)) }
        confirming, failed = targets.partition { |target| stamped[target[:stamp_key]] }
        # the keys are removed whatever became of the stamps
        delete_keys(failed)
        removed = expunge_keys(confirming)
        targets.reject { |target| confirmed?(target, stamped, removed) }
      end

      # Users whose stamp was refused: deleted, no confirmation asked.
      def delete_keys(targets)
        answers { @cache.delete_many(keys_of(targets), &method(:keep_error)) } if targets.any?
      end

      # @return [Hash{String => Boolean}] whether each key is certainly gone
      def expunge_keys(targets)
        return {} if targets.empty?

        answers { @cache.expunge_many(keys_of(targets), &method(:keep_error)) }
      end

      def keys_of(targets)
        targets.flat_map { |target| target[:keys] }.uniq
      end

      # A backend whose multi-key call raises as a whole confirmed nothing.
      def answers
        yield
      rescue StandardError => e
        keep_error(e)
        {}
      end

      # The user's stamp was written and every one of its keys removed.
      def confirmed?(target, stamped, removed)
        stamped[target[:stamp_key]] && target[:keys].all? { |key| removed[key] }
      end

      def fresh_stamps(targets)
        targets.to_h { |target| [target[:stamp_key], SecureRandom.hex(8)] }
      end

      # The last error a store call raised, for the failure report.
      def keep_error(error)
        @error = error
      end

      # The store answers: what is owed from before can be made now.
      def succeeded
        Invalidation.store_answered!
        Invalidation.retry_owed
      end

      def failed(targets, attempts)
        Invalidation.store_failed!
        targets.each do |target|
          Invalidation.owe(**target)
          Failure.report(operation: :invalidate, **target.slice(:user_id, :keys), error: @error, attempts: attempts)
        end
      end
    end
  end
end
