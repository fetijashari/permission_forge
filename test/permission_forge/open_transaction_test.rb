# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Which transactions count as open, which of them are treated as reading
  # from a snapshot, when one has finished, and when a block registered with
  # one runs — asked of the adapter's transactions on every Rails version.
  #
  # These tests run inside the transaction Rails wraps a test in: a
  # transaction that is not joinable, which does not count.
  class OpenTransactionTest < ActiveSupport::TestCase
    # A record whose after_commit raises, the way a host app's may.
    class RaisingField < PermissionForge::ResourceField
      after_commit { raise 'host callback bug' }
    end

    # --- before_commit ---------------------------------------------------------------

    test 'a before_commit block that raises makes the commit fail and the transaction roll back' do
      error = assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          create_permission_set(name: 'Guarded')
          OpenTransaction.current.before_commit { raise 'refused' }
        end
      end
      assert_equal 'refused', error.message
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Guarded')
    end

    test 'a before_commit block registered in a savepoint runs at the outermost commit, before the COMMIT' do
      ran = []
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          OpenTransaction.current.before_commit { ran << :before }
          OpenTransaction.current.after_commit { ran << :after }
        end
        assert_empty ran
      end
      assert_equal %i[before after], ran
    end

    test 'a before_commit block registered in a savepoint that rolls back never runs' do
      ran = false
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          OpenTransaction.current.before_commit { ran = true }
          raise ActiveRecord::Rollback
        end
      end
      assert_not ran
    end

    # --- which transactions count ----------------------------------------------------

    test 'the transaction that wraps a test does not count' do
      assert_equal 1, ActiveRecord::Base.connection.open_transactions
      assert_nil OpenTransaction.current
    end

    test 'a transaction counts' do
      ActiveRecord::Base.transaction { assert_instance_of OpenTransaction, OpenTransaction.current }
    end

    test 'a savepoint counts, and is another subject than the transaction around it' do
      ActiveRecord::Base.transaction do
        outer = OpenTransaction.current
        ActiveRecord::Base.transaction(requires_new: true) do
          assert_not_same outer.subject, OpenTransaction.current.subject
        end
      end
    end

    test 'a transaction that is not joinable counts inside an ordinary one' do
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true, joinable: false) { assert_not_nil OpenTransaction.current }
      end
    end

    # test-prof's before_all / let_it_be and DatabaseCleaner's transaction
    # strategy put a second non-joinable transaction around a test.
    test 'transactions that are not joinable do not count, however many there are' do
      connection = ActiveRecord::Base.connection
      connection.begin_transaction(joinable: false)

      assert_equal 2, connection.open_transactions
      assert_nil OpenTransaction.current
      ActiveRecord::Base.transaction { assert_not_nil OpenTransaction.current }
    ensure
      connection.rollback_transaction
    end

    test 'the same transaction is the same subject each time it is asked for' do
      ActiveRecord::Base.transaction do
        assert_same OpenTransaction.current.subject, OpenTransaction.current.subject
      end
    end

    # --- config.snapshot_transactions ------------------------------------------------

    test 'anything but :auto, true or false is refused' do
      ['true', 'auto', nil, 1].each do |value|
        error = assert_raises(PermissionForge::ConfigurationError) do
          PermissionForge.configuration.snapshot_transactions = value
        end
        assert_includes error.message, value.inspect
      end
      assert_equal :auto, PermissionForge::Configuration.new.snapshot_transactions
    end

    # A Rails that keeps its open transactions somewhere else must not be
    # answered from the innermost one alone: that says "not open" for a
    # non-joinable transaction inside an ordinary one.
    test 'a transaction manager without the stack this gem reads raises instead of guessing' do
      manager = Object.new
      connection = Struct.new(:transaction_manager).new(manager)

      error = assert_raises(PermissionForge::ConfigurationError) { OpenTransaction.stack_of(connection) }
      assert_includes error.message, ActiveRecord.version.to_s
    end

    test 'true: every open transaction withholds' do
      PermissionForge.configuration.snapshot_transactions = true

      assert_nil OpenTransaction.withholding
      ActiveRecord::Base.transaction do
        assert_predicate OpenTransaction.current, :snapshot?
        assert_not_nil OpenTransaction.withholding
      end
    end

    test 'false: no transaction withholds, and the connection is not even asked' do
      PermissionForge.configuration.snapshot_transactions = false
      pool = PermissionForge::PermissionSet.connection_pool
      asked = 0
      pool.define_singleton_method(:active_connection?) do
        asked += 1
        super()
      end

      ActiveRecord::Base.transaction do
        asked = 0
        assert_nil OpenTransaction.withholding
        assert_equal 0, asked
        assert_not OpenTransaction.current.snapshot?
      end
    ensure
      pool.singleton_class.send(:remove_method, :active_connection?)
    end

    test 'auto: decided by the adapter — SQLite and MySQL read from a snapshot, PostgreSQL does not' do
      adapter = ActiveRecord::Base.connection.adapter_name
      expected = !OpenTransaction::READ_COMMITTED_ADAPTERS.include?(adapter)

      ActiveRecord::Base.transaction do
        assert_equal expected, OpenTransaction.current.snapshot?, adapter
        assert_equal expected, !OpenTransaction.withholding.nil?, adapter
      end
    end

    test 'auto: an adapter that reads committed rows withholds nothing, one that is not known does' do
      connection = ActiveRecord::Base.connection
      adapters = { 'PostgreSQL' => false, 'PostGIS' => false, 'Mysql2' => true, 'Trilogy' => true, 'SQLite' => true, 'SomethingElse' => true }
      adapters.each do |name, expected|
        replace_singleton_method(connection, :adapter_name) { name }

        ActiveRecord::Base.transaction do
          assert_equal expected, OpenTransaction.current.snapshot?, name
          assert_equal expected, !OpenTransaction.withholding.nil?, name
        end
      end
    ensure
      connection.singleton_class.send(:remove_method, :adapter_name)
    end

    test 'auto on PostgreSQL: a transaction on the stack opened at repeatable read or stronger is a snapshot' do
      connection = ActiveRecord::Base.connection
      replace_singleton_method(connection, :adapter_name) { 'PostgreSQL' }
      levels = { nil => false, read_committed: false, read_uncommitted: false, repeatable_read: true, serializable: true, 'serializable' => true }

      levels.each do |level, expected|
        ActiveRecord::Base.transaction do
          # what Rails keeps of `transaction(isolation: level)`, set here on the transaction of the test's block
          connection.current_transaction.instance_variable_set(:@isolation_level, level)

          assert_equal expected, OpenTransaction.current.snapshot?, level.inspect
          ActiveRecord::Base.transaction(requires_new: true) do
            assert_equal expected, OpenTransaction.current.snapshot?, "#{level.inspect}, asked inside a savepoint"
          end
        end
      end
    ensure
      connection.singleton_class.send(:remove_method, :adapter_name)
    end

    # --- rails console --sandbox -------------------------------------------------------

    test 'the one transaction of a sandbox console counts and withholds, whatever the setting' do
      PermissionForge.configuration.snapshot_transactions = false
      Rails.application.sandbox = true

      assert_predicate OpenTransaction, :sandbox?
      assert_not_nil OpenTransaction.current
      assert_not_nil OpenTransaction.withholding
    ensure
      Rails.application.sandbox = false
    end

    test 'outside a sandbox console nothing says sandbox' do
      assert_not OpenTransaction.sandbox?
    end

    # --- finished? and rolled_back? ---------------------------------------------------

    test 'a transaction has finished once it committed, and was not rolled back' do
      each_kind do |open|
        transaction = nil
        open.call do
          transaction = OpenTransaction.current
          assert_equal false, transaction.finished?
          assert_equal false, transaction.rolled_back?
        end

        assert_equal true, transaction.finished?
        assert_equal false, transaction.rolled_back?
      end
    end

    test 'a transaction has finished once it rolled back, and says so' do
      each_kind do |open|
        transaction = nil
        open.call do
          transaction = OpenTransaction.current
          raise ActiveRecord::Rollback
        end

        assert_equal true, transaction.finished?
        assert_equal true, transaction.rolled_back?
      end
    end

    test 'a savepoint that was released has not finished the transaction it was asked in' do
      ActiveRecord::Base.transaction do
        inner = nil
        ActiveRecord::Base.transaction(requires_new: true) { inner = OpenTransaction.current }

        assert_equal false, inner.finished?, 'the outermost transaction is still open'
        assert_equal false, inner.rolled_back?
      end
    end

    test 'a savepoint that was rolled back says so while the transaction around it goes on' do
      ActiveRecord::Base.transaction do
        inner = nil
        ActiveRecord::Base.transaction(requires_new: true) do
          inner = OpenTransaction.current
          raise ActiveRecord::Rollback
        end

        assert_equal true, inner.rolled_back?
        assert_equal false, inner.finished?
      end
    end

    test 'a released savepoint is rolled back after all when the transaction around it rolls back' do
      inner = nil
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) { inner = OpenTransaction.current }
        assert_equal false, inner.rolled_back?
        raise ActiveRecord::Rollback
      end

      assert_equal true, inner.rolled_back?
      assert_equal true, inner.finished?
    end

    # A user that holds the hash it built inside a transaction may be put in a
    # cache; under ActiveRecord's 6.1 marshalling format every instance
    # variable is dumped with it.
    test 'a marshalled transaction comes back finished, also while the original is still open' do
      each_kind do |open|
        open.call do
          transaction = OpenTransaction.current

          copy = Marshal.load(Marshal.dump(transaction))

          assert_equal true, copy.finished?
          assert_equal false, copy.rolled_back?
          assert_equal false, transaction.finished?
        end
      end
    end

    # What was read inside a transaction can be used only on its connection:
    # another connection does not see those rows. (The threads of a test
    # share one connection, so another connection is stood in for.)
    test 'a transaction is visible while it stands, and on its own connection only' do
      each_kind do |open|
        transaction = nil
        open.call do
          transaction = OpenTransaction.current
          assert_equal true, transaction.visible?
          assert_equal(false, on_another_connection { transaction.visible? })
          assert_equal false, Marshal.load(Marshal.dump(transaction)).visible?
        end

        assert_equal false, transaction.visible?
      end
    end

    # --- after_commit ---------------------------------------------------------------------

    test 'a block runs once the transaction has committed, and not before' do
      each_kind do |open|
        ran = []
        open.call do
          OpenTransaction.current.after_commit { ran << ActiveRecord::Base.connection.open_transactions }
          assert_empty ran
        end

        assert_equal [1], ran, 'after the transaction left the stack: only the one of the test is left'
      end
    end

    test 'a block does not run when the transaction rolls back' do
      each_kind do |open|
        ran = false
        open.call do
          OpenTransaction.current.after_commit { ran = true }
          raise ActiveRecord::Rollback
        end

        assert_not ran
      end
    end

    test 'a block registered in a savepoint runs when the outermost transaction commits' do
      [{ requires_new: true }, { requires_new: true, joinable: false }].each do |options|
        ran = []
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(**options) { OpenTransaction.current.after_commit { ran << :committed } }
          assert_empty ran, "#{options}: the savepoint was released, the transaction is still open"
        end

        assert_equal [:committed], ran, options.to_s
      end
    end

    test 'a block registered in a savepoint is dropped when that savepoint rolls back' do
      [{ requires_new: true }, { requires_new: true, joinable: false }].each do |options|
        ran = false
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(**options) do
            OpenTransaction.current.after_commit { ran = true }
            raise ActiveRecord::Rollback
          end
        end

        assert_not ran, options.to_s
      end
    end

    test 'a block registered in a savepoint is dropped when the transaction around it rolls back later' do
      [{ requires_new: true }, { requires_new: true, joinable: false }].each do |options|
        ran = false
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(**options) { OpenTransaction.current.after_commit { ran = true } }
          raise ActiveRecord::Rollback
        end

        assert_not ran, options.to_s
      end
    end

    test 'a block is not disturbed by records saved in the same transaction' do
      set = create_permission_set
      ran = 0

      ActiveRecord::Base.transaction do
        set.update!(description: 'one')
        OpenTransaction.current.after_commit { ran += 1 }
        set.update!(description: 'two')
      end

      assert_equal 1, ran
      assert_equal 'two', set.reload.description
    end

    # The reviewer's finding 1: Rails finishes every record enlisted in a
    # transaction, also when an after_commit of another one raises. (A block
    # registered through ActiveRecord::Transaction#after_commit is skipped
    # then — which is why that API is not used.)
    test 'a block runs although an after_commit of another record raises, saved before it or after it' do
      field = create_resource_field(resource: create_resource(permission_set: create_permission_set), name: 'name')
      raising = RaisingField.find(field.id)

      %i[before after].each do |position|
        ran = false
        assert_raises(RuntimeError) do
          ActiveRecord::Base.transaction do
            raising.update!(label: "changed #{position}") if position == :before
            OpenTransaction.current.after_commit { ran = true }
            raising.update!(label: "changed #{position}") if position == :after
          end
        end

        assert ran, "the record that raises was saved #{position} the block was registered"
      end
    end

    test 'a block runs although a block registered through the public API of Rails raises' do
      skip 'Rails 7.1 has no ActiveRecord::Transaction#after_commit' unless ActiveRecord::Base.respond_to?(:current_transaction)

      ran = false
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          ActiveRecord::Base.current_transaction.after_commit { raise 'enqueue failed' }
          OpenTransaction.current.after_commit { ran = true }
        end
      end

      assert ran
    end

    private

    # Every way a transaction can be the open one in a test: an ordinary one,
    # a savepoint, and one that is not joinable inside an ordinary one.
    # The calling thread works on a connection of its own.
    def on_another_connection
      pool = PermissionForge::PermissionSet.connection_pool
      elsewhere = Object.new
      pool.define_singleton_method(:with_connection) { |*, &block| block.call(elsewhere) }
      yield
    ensure
      pool.singleton_class.send(:remove_method, :with_connection)
    end

    def each_kind
      yield ->(&body) { ActiveRecord::Base.transaction(&body) }
      yield ->(&body) { ActiveRecord::Base.transaction { ActiveRecord::Base.transaction(requires_new: true, &body) } }
      yield ->(&body) { ActiveRecord::Base.transaction { ActiveRecord::Base.transaction(requires_new: true, joinable: false, &body) } }
    end
  end

  # The same against real transactions: no transaction of a test around them,
  # so COMMIT is a COMMIT. Nothing is written.
  class OpenTransactionWithoutTestTransactionTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    test 'outside a transaction nothing is open' do
      assert_equal 0, ActiveRecord::Base.connection.open_transactions
      assert_nil OpenTransaction.current
      assert_nil OpenTransaction.withholding
    end

    test 'a transaction is open, and so is everything nested in it' do
      ActiveRecord::Base.transaction do
        assert_not_nil OpenTransaction.current
        ActiveRecord::Base.transaction(requires_new: true) { assert_not_nil OpenTransaction.current }
        ActiveRecord::Base.transaction(requires_new: true, joinable: false) { assert_not_nil OpenTransaction.current }
      end
    end

    test 'a thread that holds no connection has no transaction, whatever another thread has open' do
      ActiveRecord::Base.transaction { assert_nil(Thread.new { OpenTransaction.current }.value) }
    end

    # Known limit: this is what the transaction of a test looks like, and
    # Rails runs commit callbacks inside it as if there were no transaction.
    test 'a single transaction that is not joinable is not recognised' do
      ActiveRecord::Base.transaction(joinable: false) do
        assert_nil OpenTransaction.current
        ActiveRecord::Base.transaction { assert_not_nil OpenTransaction.current }
      end
    end

    test 'a block registered inside a non-joinable transaction in an ordinary one runs after the COMMIT' do
      ran = []

      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
          OpenTransaction.current.after_commit { ran << ActiveRecord::Base.connection.open_transactions }
        end
        assert_empty ran
      end

      assert_equal [0], ran
    end

    test 'a before_commit block that raises rolls a real transaction back and raises to its opener' do
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          PermissionForge::PermissionSetGroup.create!(name: 'Guarded real', uuid: SecureRandom.uuid)
          OpenTransaction.current.before_commit { raise 'refused' }
        end
      end
      assert_not PermissionForge::PermissionSetGroup.unscoped.exists?(name: 'Guarded real')
      assert_equal 0, ActiveRecord::Base.connection.open_transactions
    ensure
      PermissionForge::PermissionSetGroup.unscoped.where(name: 'Guarded real').delete_all
      PermissionForge::AuditEvent.unscoped.delete_all
    end

    test 'a block runs after the COMMIT of an ordinary transaction and never after its ROLLBACK' do
      ran = []

      ActiveRecord::Base.transaction { OpenTransaction.current.after_commit { ran << :committed } }
      ActiveRecord::Base.transaction do
        OpenTransaction.current.after_commit { ran << :rolled_back }
        raise ActiveRecord::Rollback
      end

      assert_equal [:committed], ran
    end

    # A connection that is reset or closed in mid-transaction never ends the
    # transaction object: it just leaves the connection's stack.
    test 'a transaction that left the stack without ending has finished' do
      connection = ActiveRecord::Base.connection
      connection.begin_transaction
      transaction = OpenTransaction.current
      assert_equal false, transaction.finished?

      connection.reset!

      assert_equal true, transaction.finished?
    end

    # The isolation level Rails was given, read off the real transaction: no
    # query is sent to find out.
    test 'auto on PostgreSQL: only a transaction opened at repeatable read or serializable is a snapshot' do
      skip 'needs PostgreSQL' unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, payload| queries << payload[:sql] }
      answers = {}
      ActiveRecord::Base.transaction { answers[:default] = OpenTransaction.current.snapshot? }
      ActiveRecord::Base.transaction(isolation: :read_committed) { answers[:read_committed] = OpenTransaction.current.snapshot? }
      ActiveRecord::Base.transaction(isolation: :repeatable_read) do
        answers[:repeatable_read] = OpenTransaction.current.snapshot?
        ActiveRecord::Base.transaction(requires_new: true) { answers[:savepoint_inside] = OpenTransaction.current.snapshot? }
      end
      ActiveRecord::Base.transaction(isolation: :serializable) { answers[:serializable] = !OpenTransaction.withholding.nil? }

      assert_equal({ default: false, read_committed: false, repeatable_read: true, savepoint_inside: true, serializable: true }, answers)
      assert_empty(queries.grep(/transaction_isolation|SHOW /i))
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
