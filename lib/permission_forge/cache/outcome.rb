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
    # - `in_request`: the operation ran inside a request a server process
    #   served (the admin or the API: Audit::Source 'admin_ui' / 'api'), so
    #   on a process-local store that server process did see it and the
    #   *other* web workers and the job processes kept theirs; false for a
    #   rake task, a runner, a console, a job or a plain service call, where
    #   the web and job processes all kept theirs;
    # - `unconfirmed`: how many users the store did not confirm (nil when not
    #   known yet).
    #
    # Made by Cache::Report, the one way a service measures an invalidation.
    #
    # @api private
    Outcome = Data.define(:confirmed, :process_local, :unconfirmed, :in_request) do
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
            in_request: hash[:in_request] == true)
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
