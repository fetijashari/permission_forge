# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options for what happens when the cache store fails
    # ({PermissionForge::Cache::Failure}) and for what is cached from inside a
    # database transaction ({PermissionForge::OpenTransaction}).
    #
    # @api public
    module CacheSettings
      # Optional callback when the cache store fails an invalidation: a stamp
      # or a removal it did not confirm after the retries, an entry that could
      # not be removed, or an error inside an after_commit invalidation. The
      # process that failed makes the invalidation when the store answers
      # again (Cache::Backlog); until then, and in other processes, a cached
      # permission hash may be out of date until cache_ttl.
      #
      # Nothing is raised (a raising after_commit makes Rails skip the
      # callbacks of the remaining records); the failure is logged at error
      # level, published as the `cache_failure.permission_forge` notification,
      # and handed to this hook. Receives (operation:, user_id:, keys:,
      # error:, **details). Errors raised by the hook are logged and swallowed.
      #
      #   config.on_cache_failure = ->(operation:, user_id:, **) {
      #     Sentry.capture_message("permission cache: #{operation} failed for user #{user_id}")
      #   }
      attr_accessor :on_cache_failure

      # Whether a database transaction is treated as reading from a snapshot —
      # the rows as they were when it began, whatever others have committed
      # since (REPEATABLE READ or stronger). A permission hash built inside
      # such a transaction can be older than an invalidation that has already
      # finished, so it is not cached: the request uses it, and
      # `regenerate_permissions` / `invalidate_permissions` called there take
      # effect in the cache once the transaction has committed.
      #
      #   :auto  (default) decided from what Rails knows, without asking the
      #          server: yes on MySQL (its default isolation) and SQLite; on
      #          PostgreSQL only inside a transaction opened with
      #          `isolation: :repeatable_read` or `:serializable`. Any other
      #          adapter counts as a snapshot.
      #   true   every transaction — for a PostgreSQL whose default isolation
      #          was raised for the database or the role
      #          (`default_transaction_isolation`).
      #   false  none — for a MySQL run at READ COMMITTED. Inside a
      #          transaction everything is then cached and invalidated as it
      #          is outside one.
      #
      # Where transactions read from a snapshot, permissions first read
      # inside a transaction are built once per transaction and not cached:
      # read them once before a loop of saves.
      attr_reader :snapshot_transactions

      SNAPSHOT_TRANSACTIONS = [:auto, true, false].freeze

      # @raise [PermissionForge::ConfigurationError] for anything else (a
      #   string from ENV, say), which would otherwise pass for :auto
      def snapshot_transactions=(value)
        unless SNAPSHOT_TRANSACTIONS.include?(value)
          raise PermissionForge::ConfigurationError,
                "snapshot_transactions must be :auto, true or false (got #{value.inspect})"
        end

        @snapshot_transactions = value
      end

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_cache_failure_defaults
        @on_cache_failure = nil
        @snapshot_transactions = :auto
      end
    end
  end
end
