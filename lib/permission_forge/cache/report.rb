# frozen_string_literal: true

require_relative 'outcome'

module PermissionForge
  module Cache
    # The one way a service measures the cache work it does: runs the block
    # under Cache::Failure.collect (so a host's override of
    # invalidate_permissions decides nothing), asks the store once whether it
    # is process-local, and answers a Cache::Outcome.
    #
    #   outcome = Cache::Report.of { user.invalidate_permissions }        # one user
    #   outcome = Cache::Report.of(user_ids: ids) { ids.each { ... } }   # several: unconfirmed counted per user
    #
    #   report = Cache::Report.new                 # when the summary event is written inside the measured block
    #   report.pending.event_data                  # the scope known in advance, nothing confirmed yet
    #   report.measure { ... }.value
    #   report.outcome(user_ids: ids)
    #
    # @api private
    class Report
      # @return [Object] what the measured block returned
      attr_reader :value

      class << self
        # Measures the block's cache work.
        #
        # @param user_ids [Array, nil] the users invalidated (nil: one, unnamed)
        # @param deferred [Boolean, Object] truthy when the invalidation follows
        #   the caller's transaction: nothing is confirmed yet
        # @return [Outcome]
        def of(user_ids: nil, deferred: false, &)
          measure(&).outcome(user_ids: user_ids, deferred: deferred)
        end

        # @return [Report] measured; `value` holds what the block returned
        def measure(&)
          new.measure(&)
        end
      end

      # Runs the block, collecting the cache failures reported inside it.
      #
      # @return [Report] self
      def measure
        @collected = Failure.collect { @value = yield }
        self
      end

      # Whether the store lives in this process only — asked once per report.
      #
      # @return [Boolean]
      def process_local?
        @process_local = PermissionForge.cache.process_local? if @process_local.nil?
        @process_local
      end

      # Those of `user_ids` whose invalidation the store confirmed.
      #
      # @param user_ids [Array]
      # @return [Array]
      def confirmed(user_ids)
        collected.confirmed(user_ids)
      end

      # The outcome before the measurement (the summary event of a service
      # that invalidates after writing it records this).
      #
      # @return [Outcome]
      def pending
        Outcome.deferred(process_local: process_local?)
      end

      # @param user_ids [Array, nil] the users invalidated, to count the
      #   unconfirmed ones (nil: one unnamed — any failure counts as one)
      # @param unconfirmed [Integer, nil] a count the caller made itself
      #   (PermissionCacheClearer counts by slice)
      # @param deferred [Boolean, Object] truthy: nothing is confirmed yet
      # @return [Outcome]
      def outcome(user_ids: nil, unconfirmed: nil, deferred: false)
        return pending if deferred

        unconfirmed ||= count_unconfirmed(user_ids)
        Outcome.new(confirmed: unconfirmed.zero?, process_local: process_local?, unconfirmed: unconfirmed)
      end

      private

      def collected
        @collected || Failure::Collected.new
      end

      def count_unconfirmed(user_ids)
        return user_ids.size - confirmed(user_ids).size if user_ids

        collected.to_a.empty? ? 0 : 1
      end
    end
  end
end
