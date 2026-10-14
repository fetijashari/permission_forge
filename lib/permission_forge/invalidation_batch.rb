# frozen_string_literal: true

module PermissionForge
  # What the permission records committed by one transaction have already
  # invalidated, so the next record of that commit does not repeat it: a
  # "Review and save" that writes 20 records in a Permission Set assigned to
  # 50 people invalidates 50 hashes, not 1,000.
  #
  # A batch never holds work that only it knows about. Each record still
  # invalidates in its own after_commit (Concerns::InvalidatesInBatch); the
  # batch remembers what was done after the commit — which users (#once) and
  # which affected-user lookups (#fetch) — and keeps a second copy of what
  # records noted for the commit (#note). Mistrusting or losing a batch
  # therefore costs repeated invalidations, never one a record would have
  # made on its own.
  #
  # Lifecycle:
  #   1. A record joins the batch still open on its thread and connection when
  #      it is written (.join). An open batch has been used by no commit, so
  #      it remembers nothing — joining one cannot bring anything stale along.
  #   2. The first after_commit of a record that joined claims it (#claim):
  #      from then on nothing can join, and the batch notes where the claim
  #      happened — the transaction depth of its connection and the ambient
  #      tenant.
  #   3. Later records of that commit claim it from the same place and reuse
  #      what it remembers. A claim from anywhere else is refused, and that
  #      record invalidates on its own.
  #
  # Why the depth: a batch must only be reused by records whose transaction had
  # committed before the batch remembered anything. While a record's
  # transaction is open it sits on the connection's transaction stack; its
  # after_commit runs once it has been popped. So everything remembered at the
  # depth a record sees in its own after_commit was remembered after that
  # record's transaction left the stack — after its commit. Without the check,
  # a transaction nested in a non-joinable one (it runs its commit callbacks
  # while the outer transaction is still open) would cover for the outer
  # transaction's records, whose rows are not visible to anyone else yet.
  #
  # Why the tenant: lookups and cache keys follow the ambient tenant, so what
  # was remembered under one tenant says nothing about another.
  #
  # What it remembers is forgotten as soon as another permission record is
  # written (.note_write): the commit's after_commit callbacks are not the only
  # code that runs between two of them. A callback in between may write a
  # record whose own invalidation comes too early to count — in a transaction
  # nested in a non-joinable one it runs at the savepoint release, before the
  # COMMIT anyone else can see. The records still waiting then invalidate
  # again, after that write, as they did before there were batches. The count
  # of writes is kept for the whole process: such a write may be made in
  # another fiber or thread than the one the commit runs on.
  # (Notes — #note — are kept: they say what has to be done, not what was.)
  #
  # @api private
  class InvalidationBatch
    # The ExecutionState slot of the batch still open on this thread (fiber
    # under Rails' fiber isolation).
    THREAD_KEY = :pf_open_invalidation_batch

    # Guards @writes increments; reads are lock-free.
    WRITES_MUTEX = Mutex.new

    class << self
      # The batch a record being written on `connection` joins: the one still
      # open on this thread for that connection, else a new one.
      #
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
      # @return [InvalidationBatch]
      def join(connection)
        note_write
        current = ExecutionState[THREAD_KEY]
        return current if current&.open_on?(connection)

        ExecutionState[THREAD_KEY] = new(connection)
      end

      # A permission record is being written somewhere in this process: every
      # batch forgets what it remembers before it is reused (see #claim).
      #
      # @return [void]
      def note_write
        WRITES_MUTEX.synchronize { @writes = writes + 1 }
      end

      # @return [Integer] permission-record writes this process has made
      def writes
        @writes || 0
      end
    end

    # Without a connection the batch stands alone: it can be used at once and
    # never joined or claimed (an invalidation outside any commit).
    def initialize(connection = nil)
      @connection = connection
      @claimed_at = nil
      @writes_seen = nil
      @lookups = {}
      @done = Set.new
      @noted = {}
    end

    # @return [Boolean] whether a record written on `connection` may still join
    def open_on?(connection)
      !@claimed_at && @connection.equal?(connection)
    end

    # Called from a record's after_commit, before it uses the batch.
    #
    # @return [InvalidationBatch, nil] the batch when the commit being reported
    #   may reuse it; nil when it was claimed from somewhere else
    def claim
      return unless @connection

      place = [@connection.open_transactions, PermissionForge.ambient_tenant_id]
      unless @claimed_at
        @claimed_at = place
        release_thread
      end
      return unless @claimed_at == place

      forget_if_written_since
      self
    end

    # A lookup shared by the records of the commit.
    #
    # @param key [Object] what is looked up (e.g. [:assignments, permission_set_id])
    # @return [Object] the block's value, from the first call for this key
    def fetch(key)
      return @lookups[key] if @lookups.key?(key)

      @lookups[key] = yield
    end

    # Runs an invalidation unless the commit has already run it. The key is
    # only remembered once the block has returned: an invalidation that raised
    # was not done.
    #
    # @param key [Object] what is invalidated (e.g. [:user, user_id, tenant_id])
    # @return [void]
    def once(key)
      return if @done.include?(key)

      yield
      @done << key
    end

    # Remembers an invalidation the commit has made without #once (many
    # users in one call, Cache::HolderInvalidation) — after it was made.
    #
    # @param key [Object] what was invalidated (e.g. [:user, user_id, tenant_id])
    # @return [void]
    def done!(key)
      @done << key
    end

    # @return [Boolean] whether #once (or #done!) has already run for this key
    def done?(key)
      @done.include?(key)
    end

    # Says that something has to be invalidated when the transaction commits.
    # This never replaces the note a record keeps for itself — a record does
    # its own invalidation in its own after_commit, whatever becomes of the
    # batch. It is for the case that after_commit never runs: of two instances
    # of one row written in a transaction, Rails runs the callbacks of one,
    # and that one can find here what the other noted.
    #
    # @param kind [Symbol] which cache (e.g. :managed_actions)
    # @param value [Object] what of it (e.g. the tenant id)
    # @return [void]
    def note(kind, value)
      (@noted[kind] ||= Set.new) << value
    end

    # @param kind [Symbol]
    # @return [Array] what the records that joined have noted for this cache
    def noted(kind)
      @noted.fetch(kind, []).to_a
    end

    # A record can be marshalled (cached) while it still references the batch
    # it joined. Nothing of a batch is worth keeping, and its connection cannot
    # be dumped: the copy stands alone.
    def marshal_dump = nil

    def marshal_load(_state)
      initialize
    end

    private

    def forget_if_written_since
      writes = self.class.writes
      return if @writes_seen == writes

      @writes_seen = writes
      @lookups.clear
      @done.clear
    end

    # So the thread keeps nothing of a claimed batch (it is never joined again).
    def release_thread
      ExecutionState[THREAD_KEY] = nil if ExecutionState[THREAD_KEY].equal?(self)
    end
  end
end
