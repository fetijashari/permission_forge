# frozen_string_literal: true

module PermissionForge
  module Cache
    # What is invalidated once more when a transaction has committed.
    #
    # An invalidation made inside an open transaction comes too early for
    # everybody else: the rows it is about are not visible to them yet, so a
    # request that rebuilds right after it caches the rows as they were
    # before the commit — and keeps them. (regenerate_permissions inside a
    # transaction that reads from a snapshot leaves nothing in the cache at
    # all, which tells nobody that something changed.) So the invalidation
    # is made again when the outermost transaction has committed: once per
    # key for each transaction that asked. A rollback drops it, because
    # nothing changed.
    #
    # Used for a user's permission hash (PermissionCacheAccessor, inside a
    # transaction that reads from a snapshot) and for the managed-actions
    # index (ControllerActions::ManagedIndex, inside any open transaction).
    #
    # @api private
    class Settlement
      # The settlement of each open transaction, by the adapter's transaction
      # object. Keys and values are held weakly: a settlement lives as long
      # as the commit hook it is registered as.
      PENDING = ObjectSpace::WeakMap.new

      # @param transaction [PermissionForge::OpenTransaction]
      # @return [Settlement] the one of this transaction
      def self.for(transaction)
        subject = transaction.subject
        PENDING[subject] ||= new.tap { |settlement| transaction.after_commit { settlement.call } }
      end

      def initialize
        @work = {}
      end

      # @param key [Object] what is invalidated (e.g. [:user, id, tenant_id]):
      #   the first block given for a key is the one that runs
      # @return [void]
      def add(key, &block)
        @work[key] ||= block
      end

      # Runs among the commit callbacks of the transaction, so nothing is
      # raised: Rails would skip the callbacks that come after it.
      #
      # @return [void]
      def call
        @work.each_value { |block| run(block) }
      end

      private

      def run(block)
        block.call
      rescue StandardError => e
        Failure.report(operation: :after_commit, error: e)
      end
    end
  end
end
