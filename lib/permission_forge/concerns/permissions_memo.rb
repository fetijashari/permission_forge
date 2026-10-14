# frozen_string_literal: true

module PermissionForge
  module Concerns
    # The permission hash a user instance keeps for itself, and what retires
    # it (PermissionCacheAccessor#permissions_hash).
    #
    # A memo is good for one cache key and one
    # PermissionForge.permissions_cache_version: any invalidation or rebuild
    # in the process retires every memo, which then reads the store again.
    #
    # An instance that rebuilt or invalidated inside a transaction whose
    # hashes are withheld from the cache (OpenTransaction#withhold?) is tied
    # to that transaction:
    #   - what it built there is good while the transaction it was built in
    #     has not been rolled back and the outermost one is still open;
    #   - until the outermost one has ended it does not read the store at
    #     all — the entry there holds the rows as they were before the
    #     transaction. A memo that was retired, or dropped by a rolled-back
    #     savepoint, is built again from the transaction's rows.
    # Once the transaction has ended, the instance reads the store like any
    # other.
    #
    # The memo is one frozen object (Memo), stored and read with one instance
    # variable: an instance read on several threads at once never pairs the
    # key or version of one thread's memo with another thread's hash (for
    # another tenant, or from before an invalidation). The transaction is
    # also the tie that keeps the instance away from the store (a Memo
    # without a hash when there is none). `served` is nil for a user without
    # conditional permission sets, and otherwise what the hash was selected
    # by (ConditionalSets::Served): the accessor checks it against the
    # request context on every read (Memo#for_context).
    # The memo marshals with the user (an OpenTransaction dumps as one that
    # has finished).
    #
    # The version is per process: an instance kept across requests learns
    # only of the invalidations made in its own process. And an invalidation
    # that lands after a rebuild's stamp check, before the rebuilding
    # instance memoizes, is seen by that instance only at the next
    # invalidation or rebuild in the process (docs/architecture.md).
    #
    # @api private
    module PermissionsMemo
      # The cache key the hash is for, the
      # PermissionForge.permissions_cache_version it is good for, the open
      # transaction it was built in when it was withheld from the cache (or
      # nil), the hash, what selected it (nil without conditional sets), and
      # when the soonest assignment that went into it ends (epoch seconds;
      # nil: none ends).
      Memo = Data.define(:key, :version, :transaction, :permissions, :served, :expires_at) do
        def initialize(expires_at: nil, **)
          super
        end

        # Whether the memo still serves reads for `key`: it holds a hash, for
        # that key, under the version as it is now, no assignment that went
        # into it has ended, and — for a hash built inside a transaction —
        # that transaction still stands and this thread works on its
        # connection (OpenTransaction#visible?).
        def serves?(key)
          return false unless permissions && self.key == key && version == PermissionForge.permissions_cache_version
          return false if expires_at && Time.now.to_i >= expires_at

          transaction.nil? || transaction.visible?
        end

        # The memo as the request context (yielded for, only when the user
        # holds conditional sets) selects it: this one, a copy that remembers
        # the context when it selects the same variant, or nil when it
        # selects another (ConditionalSets::Served#reselect).
        #
        # @return [Memo, nil]
        def for_context
          return self unless served

          reselected = served.reselect(yield)
          return unless reselected

          reselected.equal?(served) ? self : with(served: reselected)
        end
      end

      # No hash, no tie.
      EMPTY_MEMO = Memo.new(key: nil, version: nil, transaction: nil, permissions: nil, served: nil, expires_at: nil)

      # Drops the memo alongside AR's own attribute/association reload, so a
      # reloaded record never serves a permissions snapshot older than its
      # attributes. (Inside a transaction it is tied to, the next read builds
      # the hash again.)
      def reload(*)
        pf_clear_permissions_memo
        super
      end

      private

      # The memo, while it is still the one for `key`, no invalidation or
      # rebuild in this process has retired it, and — for a hash built inside
      # a transaction — that transaction still stands and this thread works
      # on its connection (Memo#serves?). The memo is read once: the fields
      # of two memos are never mixed.
      #
      # @return [Memo, nil]
      def pf_memoized_permissions(key)
        memo = pf_kept_permissions_memo
        memo if memo&.serves?(key)
      end

      # The memo this instance keeps — nil for anything else under the
      # variable: ActiveRecord's 6.1 marshalling format dumps instance
      # variables, so a user cached by an earlier version of the gem brings
      # back an Array, which is no memo. The one reader of the variable.
      #
      # @return [Memo, nil]
      def pf_kept_permissions_memo
        memo = @_pf_permissions_memo
        memo if memo.is_a?(Memo)
      end

      # A memo tied to a transaction still open on another connection stays:
      # the thread in that transaction keeps what it built from its rows.
      #
      # @param memo [Memo]
      # @return [void]
      def pf_memoize_permissions(memo)
        return if pf_kept_permissions_memo&.transaction&.held_elsewhere?(memo.transaction)

        @_pf_permissions_memo = memo
      end

      # Drops the hash; the tie to a transaction stays (see
      # pf_withholding_permissions?).
      def pf_clear_permissions_memo
        pf_withhold_permissions_in(pf_kept_permissions_memo&.transaction, keep: false)
      end

      # Ties the instance to a transaction in which it invalidated: from here
      # on the store may hold what another request rebuilt from the rows as
      # they still are before the commit. A memo it keeps is good only while
      # that transaction stands.
      def pf_withhold_permissions_in(transaction, keep: true)
        memo = (pf_kept_permissions_memo if keep) || EMPTY_MEMO
        @_pf_permissions_memo = (memo.with(transaction: transaction) if transaction || memo.permissions)
      end

      # Whether the instance has to stay away from the store: the transaction
      # it is tied to has not ended, and this thread works in it (another
      # connection reads committed rows, as the store holds). Once it has
      # ended, memo and tie are dropped.
      def pf_withholding_permissions?
        tie = pf_kept_permissions_memo&.transaction
        return false unless tie
        return tie.own_connection? unless tie.finished?

        @_pf_permissions_memo = nil
        false
      end
    end
  end
end
