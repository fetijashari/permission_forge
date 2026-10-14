# frozen_string_literal: true

module PermissionForge
  module Cache
    # Says once per process that permission hashes keep being built inside a
    # database transaction that reads from a snapshot, where they are not
    # cached (PermissionCacheAccessor#pf_rebuild_permissions, config.snapshot_transactions).
    #
    # One such rebuild is nothing to mention. A job that only reads
    # permissions inside the transaction of each save, or an application that
    # wraps every request in a transaction, never caches a hash, though, and
    # rebuilds the permissions every time — and nothing else would tell it
    # why. So the rebuilds that were withheld are counted until one runs
    # outside such a transaction again, and the count reaching AFTER is
    # logged, once.
    #
    # @api private
    module WithheldNotice
      AFTER = 20
      MUTEX = Mutex.new

      class << self
        # @return [void]
        def withheld
          say = MUTEX.synchronize do
            @in_a_row = (@in_a_row || 0) + 1
            @in_a_row == AFTER && !@said && (@said = true)
          end
          log if say
        end

        # A rebuild ran outside a transaction: the count starts again.
        #
        # @return [void]
        def not_withheld
          MUTEX.synchronize { @in_a_row = 0 }
        end

        # For tests: the notice can be given again.
        def reset!
          MUTEX.synchronize { @in_a_row = @said = nil }
        end

        private

        def log
          return unless defined?(Rails) && Rails.logger

          Rails.logger.warn(
            "[PermissionForge] The last #{AFTER} permission rebuilds ran inside a database transaction that reads from " \
            'a snapshot, so none of them was cached: such a hash may be older than a change that was already ' \
            'invalidated. Read the permissions once (current_user.permissions_hash) before the loop of saves or the ' \
            'transaction — or, if this database runs at READ COMMITTED, set config.snapshot_transactions = false. ' \
            'This is logged once per process.'
          )
        end
      end
    end
  end
end
