# frozen_string_literal: true

module PermissionForge
  module Cache
    # What one cache-touching operation did to the cached permissions, as
    # every surface reports it — the terminal (RakeOutput), the admin flash
    # (CacheConfirmation), the API body and the summary audit event:
    #
    # - `confirmed`: true when the store confirmed every removal the
    #   operation asked for (Cache::Failure reported nothing), false when it
    #   did not (the old permissions may be served until cache_ttl), nil when
    #   that is not known where the outcome is made — the invalidation
    #   follows the surrounding transaction's commit (Cache::Settlement), or
    #   the summary event is written before the cache work runs;
    # - `process_local`: the store lives in each process
    #   (Cache::Base#process_local?: `cache_backend = :memory`, or Rails.cache a
    #   `:memory_store`), so only the process that ran the operation saw it;
    # - `in_request`: the operation ran in a server process (the admin or
    #   the API: Audit::Source 'admin_ui' / 'api', or any code of a web
    #   server process, a host controller among it: Report.in_request?), so
    #   on a process-local store that server process did see it and the
    #   *other* web workers and the job processes kept theirs; false for a
    #   rake task, a runner, a console or a job process, where every other
    #   process kept theirs;
    # - `unconfirmed`: how many users the store did not confirm (nil when not
    #   known yet);
    # - `work`: false when the operation did no cache work at all — a dry run
    #   (.none: `confirmed` nil, `unconfirmed` 0); true otherwise. Only an
    #   outcome without work carries the key in #to_h (`work: false`), so
    #   every answer of an operation that did its work keeps its four keys.
    #   A dry run used to answer `confirmed: true` for work it never did
    #   (field test round 7, E#55).
    #
    # Made by Cache::Report, the one way a service measures an invalidation.
    #
    # @api private
    Outcome = Data.define(:confirmed, :process_local, :unconfirmed, :in_request, :work) do
      # @param work [Boolean] false only for an operation that did no cache work (.none)
      def initialize(confirmed:, process_local:, unconfirmed:, in_request:, work: true)
        super
      end

      # The outcome of an operation that did no cache work (every dry run):
      # nothing asked of the store, so nothing confirmed and nobody left
      # unconfirmed; the store's scope and the origin as measured.
      #
      # @param process_local [Boolean]
      # @param in_request [Boolean]
      # @return [Outcome]
      def self.none(process_local:, in_request:)
        new(confirmed: nil, process_local: process_local, unconfirmed: 0, in_request: in_request, work: false)
      end

      # The outcome before the cache work has run, or where its result is not
      # known: nothing confirmed yet, the store's scope and the origin known
      # already.
      #
      # @param process_local [Boolean]
      # @param in_request [Boolean]
      # @return [Outcome]
      def self.deferred(process_local:, in_request:)
        new(confirmed: nil, process_local: process_local, unconfirmed: nil, in_request: in_request)
      end

      # An Outcome from what a service answered under `cache:` (its Hash, or
      # the Outcome itself).
      #
      # @param value [Outcome, Hash]
      # @return [Outcome]
      def self.wrap(value)
        return value if value.is_a?(self)

        hash = value.to_h.transform_keys(&:to_sym)
        new(confirmed: hash[:confirmed], process_local: hash[:process_local] == true, unconfirmed: hash[:unconfirmed],
            in_request: hash[:in_request] == true, work: hash[:work] != false)
      end

      # What a summary event records (string keys, as event data is stored).
      #
      # @return [Hash]
      def event_data
        { 'cache_confirmed' => confirmed, 'process_local' => process_local, 'in_request' => in_request, 'unconfirmed' => unconfirmed }
      end

      def process_local? = process_local == true
      def in_request? = in_request == true
      def confirmed? = confirmed == true
      # No cache work was done (.none: a dry run).
      def none? = work == false

      # The outcome as a service answers it: the four keys, and `work: false`
      # for an operation that did no cache work (#none?).
      #
      # @return [Hash]
      def to_h
        none? ? super : super.except(:work)
      end

      # A flash: an alert only when the store said no; a confirmation that is
      # not known yet is not a failure to announce.
      #
      # @return [Symbol] :notice or :alert
      def flash_kind = confirmed == false ? :alert : :notice

      # Which processes kept their cached permissions: `:none` (a shared
      # store), `:other_processes` (a process-local store, the operation ran
      # in a server process: the other web workers and the job processes),
      # `:servers` (a process-local store, the operation ran elsewhere: every
      # web and job process).
      #
      # @return [Symbol]
      def kept_by
        return :none unless process_local?

        in_request? ? :other_processes : :servers
      end
    end
  end
end
