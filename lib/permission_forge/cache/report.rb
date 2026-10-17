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
    # Measured inside a caller's transaction the outcome is pending
    # (#deferred?, the one reading): the invalidations follow its commit.
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
        # @return [Outcome] pending (#deferred?) inside a caller's transaction
        def of(user_ids: nil, &)
          measure(&).outcome(user_ids: user_ids)
        end

        # @return [Report] measured; `value` holds what the block returned
        def measure(&)
          new.measure(&)
        end
      end

      # Runs the block, collecting the cache failures reported inside it.
      # Whether the work waits for a caller's transaction is read here, once,
      # before the first block (#deferred?).
      #
      # @return [Report] self
      def measure
        @deferred = PermissionForge::OpenTransaction.current ? true : false if @deferred.nil?
        @collected = Failure.collect { @value = yield }
        self
      end

      # The one reading of "deferred" for every operation that measures its
      # cache work: a caller's transaction was open when it was measured
      # (OpenTransaction.current), so the invalidations follow its commit
      # (the rows' own after_commit, Cache::Settlement) and nothing is
      # confirmed yet. False before anything was measured.
      #
      # @return [Boolean]
      def deferred? = @deferred == true

      # Whether the store lives in this process only — asked once per report.
      #
      # @return [Boolean]
      def process_local?
        @process_local = PermissionForge.cache.process_local? if @process_local.nil?
        @process_local
      end

      # Whether the operation runs in a server process (Report.in_request?).
      #
      # @return [Boolean]
      def in_request?
        @in_request = Report.in_request? if @in_request.nil?
        @in_request
      end

      # The one definition of "the operation ran in a server process": the
      # audit context says it came from the admin or the API, or this process
      # is a web server (Warnings.server_process?: a host controller, or a
      # job run inline by Puma, whatever its audit source). A rake task, a
      # runner, a console or a job process is a process of its own.
      #
      # @return [Boolean]
      def self.in_request?
        REQUEST_SOURCES.include?(PermissionForge::Audit::Source.current) || PermissionForge::Warnings.server_process?
      end

      # The audit sources of a request a server process serves.
      REQUEST_SOURCES = %w[admin_ui api].freeze

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
        Outcome.deferred(process_local: process_local?, in_request: in_request?)
      end

      # The outcome of an operation that does no cache work (a dry run):
      # Outcome.none, with the store's scope and the origin as this report
      # reads them.
      #
      # @return [Outcome]
      def none
        Outcome.none(process_local: process_local?, in_request: in_request?)
      end

      # The outcome of a dry run, measured nowhere (Report#none).
      #
      # @return [Outcome]
      def self.none
        new.none
      end

      # @param user_ids [Array, nil] the users invalidated, to count the
      #   unconfirmed ones (nil: one unnamed — any failure counts as one)
      # @param unconfirmed [Integer, nil] a count the caller made itself
      #   (PermissionCacheClearer counts by slice)
      # @return [Outcome] pending while #deferred?
      def outcome(user_ids: nil, unconfirmed: nil)
        return pending if deferred?

        unconfirmed ||= count_unconfirmed(user_ids)
        Outcome.new(confirmed: unconfirmed.zero?, process_local: process_local?, unconfirmed: unconfirmed, in_request: in_request?)
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
