# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # Which connection PermissionForge::RLS works on. `ActiveRecord::Base.connection`
  # is soft-deprecated from Rails 7.2 (it raises under
  # `ActiveRecord.permanent_connection_checkout = :disallowed`) and leases a
  # connection to the calling thread for good. RLS asks for a connection for
  # the unit of work it does (`with_connection`: returned to the pool after,
  # unless the thread held one already), except for the session-scoped
  # set_user! / clear_user!, whose setting must stay on the connection the
  # request goes on using (`lease_connection`).
  #
  # Where each set_config ran is read from the sql.active_record
  # notifications (their payload names the connection). On PostgreSQL the
  # statements run for real. SQLite has no set_config: there every connection
  # gets one (a SQLite function) and the database is taken for PostgreSQL.
  # MySQL has neither: skipped. The tests run outside the transaction Rails
  # wraps a test in (and outside its pinned connection), in a thread of their
  # own that starts without a connection; nothing is written.
  class RlsConnectionTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    # Takes the database for PostgreSQL while `pretend` is set.
    module PretendPostgres
      class << self
        attr_accessor :pretend
      end

      def postgres?
        PretendPostgres.pretend ? true : super
      end
    end
    PermissionForge::RLS.singleton_class.prepend(PretendPostgres)

    SetConfigCall = Struct.new(:connection, :value, :local)
    SET_CONFIG = /set_config\('[^']*', '([^']*)', (true|false)\)/

    setup do
      @adapter = pool.db_config.adapter.to_s
      skip "set_config is PostgreSQL's; the tests stand it in on SQLite only (adapter: #{@adapter})" unless postgresql? || sqlite?

      @calls = Queue.new
      calls = @calls
      @subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        match = SET_CONFIG.match(payload[:sql].to_s)
        calls << SetConfigCall.new(payload[:connection], match[1], match[2] == 'true') if match
      end
      stand_in_set_config if sqlite?
    end

    teardown do
      ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
      ActiveRecord::ConnectionAdapters::AbstractAdapter.skip_callback(:checkout, :after, @checkout_callback) if @checkout_callback
      PretendPostgres.pretend = false
    end

    def pool
      ActiveRecord::Base.connection_pool
    end

    def postgresql?
      @adapter.match?(/postg/i)
    end

    def sqlite?
      @adapter.match?(/sqlite/i)
    end

    # SQLite: a set_config on every connection, the ones the pool has and the
    # ones it checks out later.
    def stand_in_set_config
      register = lambda do |connection|
        connection.raw_connection.create_function('set_config', 3) { |function, _name, value, _local| function.result = value }
      end
      @checkout_callback = -> { register.call(self) }
      ActiveRecord::ConnectionAdapters::AbstractAdapter.set_callback(:checkout, :after, @checkout_callback)
      pool.connections.each { |connection| register.call(connection) }
    end

    # PostgreSQL answers postgres? itself.
    def pretend_postgres!
      PretendPostgres.pretend = true if sqlite?
    end

    # Runs the block in a new thread that holds no connection, and hands back
    # what it returned. The thread gives back whatever it still holds.
    def in_fresh_thread(&block)
      Thread.new do
        Thread.current.report_on_exception = false
        raise 'the thread started with a connection' if pool.active_connection?

        block.call
      ensure
        pool.release_connection
      end.value
    end

    def set_config_calls
      calls = []
      calls << @calls.pop until @calls.empty?
      calls
    end

    # Rails 7.2+: the deprecated reader raises.
    def with_connection_reader_disallowed
      skip 'ActiveRecord.permanent_connection_checkout arrived in Rails 7.2' unless ActiveRecord.respond_to?(:permanent_connection_checkout=)

      previous = ActiveRecord.permanent_connection_checkout
      ActiveRecord.permanent_connection_checkout = :disallowed
      yield
    ensure
      ActiveRecord.permanent_connection_checkout = previous if ActiveRecord.respond_to?(:permanent_connection_checkout=)
    end

    test 'postgres? gives the connection it took back to the pool' do
      held = in_fresh_thread do
        PermissionForge::RLS.postgres?
        pool.active_connection?
      end

      assert_not held, 'RLS.postgres? left the calling thread holding a connection'
    end

    test 'postgres? does not call the deprecated ActiveRecord::Base.connection' do
      with_connection_reader_disallowed do
        answer = in_fresh_thread { PermissionForge::RLS.postgres? }

        assert_equal postgresql?, answer
      end
    end

    test 'with_user sets the user, transaction-locally, on the connection the block queries, then gives it back' do
      pretend_postgres!
      seen, inside_transaction, held = in_fresh_thread do
        connection, open = PermissionForge::RLS.with_user(42) do
          pool.with_connection { |current| [current, current.transaction_open?] }
        end
        [connection, open, pool.active_connection?]
      end

      calls = set_config_calls
      assert_equal([[seen, '42', true]], calls.map { |call| [call.connection, call.value, call.local] })
      assert inside_transaction, 'the block runs inside the transaction set_config(…, true) is local to'
      assert_not held, 'RLS.with_user left the calling thread holding a connection'
    end

    test 'set_user! sets the user on the connection the thread keeps, and clear_user! clears it there' do
      pretend_postgres!
      kept, after_clear = in_fresh_thread do
        PermissionForge::RLS.set_user!(7)
        connection = pool.active_connection? && pool.with_connection { |current| current }
        PermissionForge::RLS.clear_user!
        [connection, pool.with_connection { |current| current }]
      end

      calls = set_config_calls
      assert kept, 'set_user! must leave its connection with the thread: the setting lives on it'
      assert_equal([[kept, '7', false], [kept, '', false]], calls.map { |call| [call.connection, call.value, call.local] })
      assert_same kept, after_clear
    end

    test 'with_user, set_user! and clear_user! do not call the deprecated ActiveRecord::Base.connection' do
      pretend_postgres!
      with_connection_reader_disallowed do
        in_fresh_thread do
          PermissionForge::RLS.with_user(1) { :ran }
          PermissionForge::RLS.set_user!(2)
          PermissionForge::RLS.clear_user!
        end

        assert_equal ['1', '2', ''], set_config_calls.map(&:value)
      end
    end

    test 'the public methods are the ones RLS always had, without connection' do
      public_methods = PermissionForge::RLS.singleton_methods.uniq

      assert_equal %i[apply_user clear_user! drift_report ensure_postgres! log_skipped_rules postgres? protected_model_classes
                      remove! run_set_config set_user! stored_digest sync! with_user].sort, public_methods.sort
    end

    test 'apply_user and run_set_config still take the arguments they took, on the connection the thread keeps' do
      pretend_postgres!
      kept = in_fresh_thread do
        PermissionForge::RLS.apply_user(5, local: false)
        PermissionForge::RLS.run_set_config('', local: false)
        pool.with_connection { |current| current }
      end

      assert_equal([[kept, '5', false], [kept, '', false]], set_config_calls.map { |call| [call.connection, call.value, call.local] })
    end
  end
end
