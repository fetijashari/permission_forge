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
    # - `process_local`: the store lives in this process only
    #   (Cache::Base#process_local?: `cache_backend = :memory`, or Rails.cache a
    #   `:memory_store`), so the web and job processes kept their entries;
    # - `unconfirmed`: how many users the store did not confirm (nil when not
    #   known yet).
    #
    # Made by Cache::Report, the one way a service measures an invalidation.
    #
    # @api private
    Outcome = Data.define(:confirmed, :process_local, :unconfirmed) do
      # The outcome before the cache work has run, or where its result is not
      # known: nothing confirmed yet, the store's scope known already.
      #
      # @param process_local [Boolean]
      # @return [Outcome]
      def self.deferred(process_local:)
        new(confirmed: nil, process_local: process_local, unconfirmed: nil)
      end

      # An Outcome from what a service answered under `cache:` (its Hash, or
      # the Outcome itself).
      #
      # @param value [Outcome, Hash]
      # @return [Outcome]
      def self.wrap(value)
        return value if value.is_a?(self)

        hash = value.to_h.transform_keys(&:to_sym)
        new(confirmed: hash[:confirmed], process_local: hash[:process_local] == true, unconfirmed: hash[:unconfirmed])
      end

      # What a summary event records (string keys, as event data is stored).
      #
      # @return [Hash]
      def event_data
        { 'cache_confirmed' => confirmed, 'process_local' => process_local, 'unconfirmed' => unconfirmed }
      end

      def process_local? = process_local == true
      def confirmed? = confirmed == true

      # A flash: an alert only when the store said no; a confirmation that is
      # not known yet is not a failure to announce.
      #
      # @return [Symbol] :notice or :alert
      def flash_kind = confirmed == false ? :alert : :notice
    end
  end
end
