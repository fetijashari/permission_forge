# frozen_string_literal: true

module PermissionForge
  # The database transaction the calling code runs in, on the connection of
  # the permission models — if one is open whose rows nobody else can see yet
  # and which may still be rolled back.
  #
  # Open means: a joinable transaction is on the connection's stack. A
  # transaction that is not joinable does not count by itself — that is how
  # Rails wraps a test (and how test-prof's `before_all` and DatabaseCleaner
  # wrap theirs): everything a test does runs inside it, and Rails treats it
  # as no transaction at all (commit callbacks run inside it). Whatever is
  # opened inside one counts, and so does a non-joinable transaction inside
  # an ordinary one. `rails console --sandbox` is one non-joinable
  # transaction too, and there it does count: nothing done in a sandbox is
  # ever committed.
  #
  # What is asked of it:
  #   - #withhold?: whether a permission hash built inside it has to stay
  #     out of the shared cache — the transaction reads from a snapshot
  #     (#snapshot?, `config.snapshot_transactions`), or it is the sandbox.
  #   - #finished?: whether it has ended since, committed or rolled back —
  #     the outermost transaction that counted, that is.
  #   - #rolled_back?: whether the transaction it was asked in, or one around
  #     it, was rolled back since. What was read inside it is void then, also
  #     while a transaction around it is still open.
  #   - #after_commit: runs a block once everybody can see what the
  #     transaction did — after the outermost one has committed — and never
  #     after this transaction, or one around it, was rolled back.
  #
  # All of it is asked of the adapter's own transaction objects, on every
  # Rails version: the stack of the connection's transaction manager (Rails
  # has no reader for it; it is `@stack` from 7.1 to 8.1), each transaction's
  # `joinable?`, `state` and `isolation_level`, and `add_record` for the
  # block, which is enlisted the way Rails enlists a record that has commit
  # callbacks. The public API of Rails 7.2+ (ActiveRecord::Transaction) is not
  # used: it does not see a transaction that is not joinable, it does not say
  # how a transaction ended, and Rails skips a block registered through it
  # when a commit callback of any record in the transaction raises.
  #
  # @api private
  class OpenTransaction
    # Isolation levels at which a transaction reads from one snapshot.
    SNAPSHOT_LEVELS = %i[repeatable_read serializable].freeze

    # Adapters whose transactions read committed rows unless they were opened
    # with a stronger isolation level. Every other adapter is taken to read
    # from a snapshot (MySQL at its default, SQLite) under `:auto`.
    READ_COMMITTED_ADAPTERS = %w[PostgreSQL PostGIS].freeze

    class << self
      # @param model [Class] a model on the connection in question
      # @return [OpenTransaction, nil] nil when no transaction is open
      def current(model = PermissionForge::PermissionSet)
        pool = model.connection_pool
        # a thread that holds no connection has no transaction
        return unless pool.active_connection?

        pool.with_connection { |connection| on(connection) }
      end

      # The open transaction, when what is built inside it must stay out of
      # the shared cache. The question a host asks before it writes a cache
      # entry of its own that is derived from the permissions.
      #
      # @return [OpenTransaction, nil]
      def withholding(model = PermissionForge::PermissionSet)
        return if PermissionForge.configuration.snapshot_transactions == false && !sandbox?

        transaction = current(model)
        transaction if transaction&.withhold?
      end

      # @return [Array] the adapter's open transactions, outermost first
      # @raise [PermissionForge::ConfigurationError] when this Rails keeps
      #   them elsewhere. Looking at the innermost transaction alone would
      #   answer, wrongly and silently: a hash a rollback takes back would be
      #   cached.
      def stack_of(connection)
        manager = connection.transaction_manager
        return manager.instance_variable_get(:@stack) if manager.instance_variable_defined?(:@stack)

        raise PermissionForge::ConfigurationError,
              "PermissionForge cannot read the open transactions of #{manager.class} (ActiveRecord " \
              "#{ActiveRecord.version}): this version of the gem does not support that Rails version"
      end

      # @return [Boolean] whether this process is `rails console --sandbox`
      def sandbox?
        return false unless defined?(Rails) && Rails.respond_to?(:application)

        application = Rails.application
        application.respond_to?(:sandbox?) && application.sandbox? == true
      end

      private

      def on(connection)
        stack = stack_of(connection)
        root = sandbox? ? stack.first : stack.find(&:joinable?)
        new(connection, root, stack.last) if root
      end
    end

    # What identifies the transaction the handle was asked for (the innermost
    # one), for as long as it is referenced.
    #
    # @return [Object] the adapter's transaction
    attr_reader :subject

    # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    # @param root [Object] the outermost transaction that counts
    # @param subject [Object] the innermost transaction
    def initialize(connection, root, subject)
      @connection = connection
      @root = root
      @subject = subject
    end

    # @return [Boolean]
    def withhold?
      self.class.sandbox? || snapshot?
    end

    # Whether the transaction is treated as reading from a snapshot:
    # `config.snapshot_transactions`, and under `:auto` the adapter and the
    # isolation level the transaction was opened with. The server is not
    # asked.
    #
    # @return [Boolean]
    def snapshot?
      setting = PermissionForge.configuration.snapshot_transactions
      return setting if [true, false].include?(setting)

      !READ_COMMITTED_ADAPTERS.include?(@connection.adapter_name) || snapshot_isolation?
    end

    # Also true when the transaction is not on the connection's stack any
    # more without having ended (the connection was reset or closed), and for
    # a copy that was marshalled.
    #
    # @return [Boolean]
    def finished?
      return true unless @root

      !!@root.state.finalized? || self.class.stack_of(@connection).none? { |transaction| transaction.equal?(@root) }
    end

    # (A transaction that rolls back marks the ones inside it as rolled back,
    # also those that had been released before.)
    #
    # @return [Boolean]
    def rolled_back?
      !!@subject&.state&.rolledback?
    end

    # Whether what was read inside it is still good: it has neither ended
    # nor been rolled back to a savepoint.
    #
    # @return [Boolean]
    def stands?
      !(finished? || rolled_back?)
    end

    # Whether what was read inside it can be used where it is asked: it
    # stands, and the calling thread (fiber) works on its connection —
    # another connection does not see its rows, which may still be rolled
    # back.
    #
    # @return [Boolean]
    def visible?
      own_connection? && stands?
    end

    # Whether the calling thread (fiber) works on its connection.
    #
    # @return [Boolean]
    def own_connection?
      pool = @connection&.pool
      return false unless pool&.active_connection?

      pool.with_connection { |connection| connection.equal?(@connection) }
    end

    # Whether what is tied to it must not be replaced, from the calling
    # thread, by what is tied to `other` (another transaction, or none): it
    # is still open, on a connection the calling thread does not work on.
    #
    # @param other [OpenTransaction, nil]
    # @return [Boolean]
    def held_elsewhere?(other)
      !(equal?(other) || finished? || own_connection?)
    end

    # @return [void]
    def after_commit(&block)
      @subject.add_record(CommitHook.new(after: block))
    end

    # Runs a block just before the outermost transaction commits — after the
    # transaction it was registered in, and every one around it, has decided
    # to commit. A block that raises makes the commit fail: Rails rolls the
    # transaction back and raises the error to the code that opened it. That
    # is how a change whose audit event could not be written is kept from
    # being committed by a caller that rescued the error (Audit).
    #
    # Never runs after this transaction, or one around it, was rolled back.
    #
    # @return [void]
    def before_commit(&block)
      @subject.add_record(CommitHook.new(before: block))
    end

    # Runs a block once, when what this transaction did is decided either
    # way: after the outermost transaction has committed, or once it — or
    # this one, or one in between — has rolled back and no transaction that
    # counts is open any more. A savepoint that rolls back while
    # transactions around it are still open hands the block to them; one
    # that is released takes it along (Rails moves its records). For what
    # must be written whichever way the caller's transaction ends: a
    # refusal or a failed sign-in (Audit::Detached), a runtime decision
    # (Audit.instrument).
    #
    # The block runs from Rails' commit or rollback, where raising would
    # replace the caller's own exception or fail a transaction that has
    # already committed: an error is reported (Rails.error) and logged,
    # never raised — also when the connection cannot say whether a
    # transaction is still open (the block then runs). Nothing is kept on a
    # record.
    #
    # @return [void]
    def after_end(&block)
      hand_on = lambda do
        enclosing = CommitHook.run_detached(-> { self.class.send(:on, @connection) if @connection&.active? })
        enclosing ? CommitHook.run_detached(-> { enclosing.after_end(&block) }) : CommitHook.run_detached(block)
      end
      @subject.add_record(CommitHook.new(after: -> { CommitHook.run_detached(block) }, rollback: hand_on))
    end

    # A user that still holds the hash it built inside a transaction can be
    # marshalled (cached). Nothing of a transaction can be dumped, and the
    # copy is in no transaction: for it, this one has finished.
    def marshal_dump = nil

    def marshal_load(_state)
      @connection = @root = @subject = nil
    end

    private

    def snapshot_isolation?
      self.class.stack_of(@connection).any? { |transaction| SNAPSHOT_LEVELS.include?(transaction.isolation_level&.to_sym) }
    end

    # Blocks in the place of a record: what Rails calls on the records of a
    # transaction when it commits or rolls back. The record moves to the
    # enclosing transaction when a nested one commits. `before_committed!` is
    # called by the transaction that runs the commit callbacks before its
    # COMMIT — an error there makes Rails roll back instead. `committed!` is
    # called after the COMMIT, for every record, also when an after_commit of
    # another one raised, and before the blocks registered through
    # ActiveRecord::Transaction#after_commit. `rolledback!` is called by the
    # transaction that rolls back (a savepoint too), and again for records left
    # when a callback of another one raised: each block runs once.
    class CommitHook
      # Runs a block where nothing may be raised (OpenTransaction#after_end).
      def self.run_detached(block)
        block.call
      rescue StandardError => e
        Rails.logger&.error("[PermissionForge] transaction end hook failed — #{e.class}: #{e.message}") if defined?(Rails)
        Rails.error.report(e, handled: true, source: 'permission_forge.open_transaction') if defined?(Rails) && Rails.respond_to?(:error)
        nil
      end

      def initialize(after: nil, before: nil, rollback: nil)
        @after = after
        @before = before
        @rollback = rollback
      end

      def trigger_transactional_callbacks?
        true
      end

      def before_committed!
        @before&.call
      end

      def committed!(*, **)
        @rollback = nil
        block = @after
        @after = nil
        block&.call
      end

      def rolledback!(*, **)
        block = @rollback
        @rollback = nil
        block&.call
      end
    end
  end
end
