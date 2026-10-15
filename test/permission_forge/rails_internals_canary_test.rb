# frozen_string_literal: true

# Run on its own (CI's rails-main job runs this file first), the canary runs
# in one process: several canaries open connections from other threads, and
# with the suite's in-memory SQLite each such connection is an empty database
# a forked worker could later check out. Inside the full suite test_helper is
# already loaded and this has no effect.
ENV['PARALLEL_WORKERS'] ||= '1'

require 'test_helper'
require 'pp'
require 'tmpdir'
require 'open3'
require 'json'
require 'active_support/cache/redis_cache_store'

# Rails-internals canary: one test per private (`:nodoc:`, private, or
# undocumented) ActiveRecord / ActiveSupport API PermissionForge relies on.
# Each test asserts that the API is there AND that it still behaves the way
# the gem depends on — arity, return shape, call order, the instance variable,
# the module a method is found in — so that a Rails upgrade that breaks one of
# them fails here, by name, instead of somewhere deep in the suite (or in
# production, where most of these fail silently: a hash cached that a
# rollback took back, a masked value in a log line, an audit event nobody
# hears).
#
# How to read a failure: the message names the API, what Rails now does, the
# places in lib/ and app/ that rely on it (found by searching for the code
# that uses it, so the list is always current) and what to change. Every
# test is a `canary_test :key`: an assertion without a message of its own,
# or a Rails that raises instead of answering, still fails with the key's
# message (FIXES). Assert only what the gem relies on: an optional argument
# or a better answer Rails adds must not fail a canary. Fix the gem, then
# the canary. A canary that is no longer needed (the gem stopped
# using the API) fails the "every touch point is still used" test: delete it.
#
# A new reliance on a private Rails API needs a canary test here (CLAUDE.md).
#
# Runs on every Rails the gem supports (CI matrix) and on Rails main (the
# allow-failure `rails-main` job), which runs this file first.

ActiveRecord::Schema.define do
  create_table :pf_canary_records, force: true do |t|
    t.string :name
    t.string :email
    t.text :prefs
    t.integer :parent_id
  end
end

# A plain model on the canary table. Never give it (or any model here) a
# Resource row: the canary watches Rails, not the gem's concerns.
class PfCanaryRecord < ApplicationRecord
  self.table_name = 'pf_canary_records'
  belongs_to :parent, class_name: 'PfCanaryRecord', optional: true, inverse_of: :children
  has_many :children, class_name: 'PfCanaryRecord', foreign_key: :parent_id, inverse_of: :parent, dependent: nil
end

module PermissionForge
  module RailsInternalsCanary
    ROOT = File.expand_path('../..', __dir__)

    # What each canary watches, and the code that relies on it (a String or
    # Regexp searched for in lib/ and app/).
    TOUCH_POINTS = {
      transaction_stack: 'instance_variable_get(:@stack)',
      transaction_joinable: 'stack.find(&:joinable?)',
      transaction_state: Regexp.union('@root.state.finalized?', '@subject&.state&.rolledback?'),
      transaction_isolation_level: 'transaction.isolation_level',
      transaction_add_record: '@subject.add_record(CommitHook.new',
      open_transactions: '@connection.open_transactions',
      connection_pool_leases: /pool\.(with_connection|lease_connection)\b/,
      generated_attribute_methods: 'send(:generated_attribute_methods)',
      attribute_methods_lock: 'owner.const_defined?(:LOCK)',
      subclass_attribute_methods: 'drop_generated_accessors(klass, masked_attribute_module)',
      read_attribute_internal: /(?<!\w)_read_attribute\(/,
      write_attribute_internal: /(?<!\w)_write_attribute\(/,
      missing_attribute: /(?<!\w)missing_attribute\(/,
      dangerous_attribute_methods: 'AttributeMethods.dangerous_attribute_methods',
      alias_attribute_semantics: "ActiveRecord.version < Gem::Version.new('7.2')",
      alias_methods_module: 'generated_attribute_methods).prepend(accessors)',
      aliases_by_attribute_name: 'klass.aliases_by_attribute_name',
      format_for_inspect: Regexp.union('format_for_inspect(name, read_attribute(name))', 'def attribute_for_inspect'),
      pretty_print: Regexp.union("ActiveRecord.gem_version < Gem::Version.new('7.2')", 'custom_inspect_method_defined?', '_has_attribute?(name)'),
      store_accessor_hooks: /def (read|write)_store_attribute\(/,
      serialization_hooks: /def (attribute_names|read_attribute)_for_serialization\b/,
      each_validator_reads: 'EachValidator.prepend(PermissionForge::Concerns::MaskedAttributes::ValidationReads::EachValidatorWindow)',
      trigger_destroy_callback: 'send(:_trigger_destroy_callback)',
      fanout_clear_cache: 'fanout.prepend(FanoutHook)',
      notifier_writer: 'notifications.prepend(NotifierHook)',
      all_listeners_for: 'notifier.all_listeners_for(notification)',
      isolated_execution_state: 'ActiveSupport::IsolatedExecutionState',
      isolated_execution_state_context: 'ActiveSupport::IsolatedExecutionState.context',
      executor_register_hook: 'app.executor.register_hook(RunHook)',
      write_multi_entries: 'instance_method(:write_multi_entries).owner',
      redis_write_multi_answer: Regexp.union('instance_variable_get(:@error_handler)', 'HandledErrors.written('),
      counter_updates: 'def update_counters(*, **)',
      local_cache: 'store.with_local_cache',
      key_matcher_anchor: Regexp.union("regexp = /^\#{lead}", "/^\#{Regexp.escape(prefix)}:/"),
      redis_store_kind: "class.name.to_s.include?('Redis')",
      default_scope: 'default_scope { pf_auto_permission_scope }',
      find_by_override: Regexp.union('def find_by(*args)', 'def find_by!(*args)'),
      relation_delegate_class: 'relation_delegate_class(ActiveRecord::Relation).prepend(InsertOnly)',
      process_action_callbacks: '_process_action_callbacks.any?',
      arel_grouping: 'Arel::Nodes::Grouping.new(predicate)',
      arel_between: Regexp.union('Arel::Nodes::Between.new(', 'Arel::Nodes.build_quoted('),
      arel_matches: 'column.matches(',
      arel_named_function: "Arel::Nodes::NamedFunction.new('COALESCE'",
      schema_cache: 'connection.schema_cache.columns_hash(',
      association_join_checks: Regexp.union('._reflect_on_association(', 'reflection.check_validity!', 'reflection.check_eager_loadable!'),
      preloader: 'ActiveRecord::Associations::Preloader.new(records:',
      sandbox: 'application.sandbox?',
      generator_commands: 'Rails::Command::GenerateCommand',
      journey_route: Regexp.union('@route.path.spec', '@route.verb', '@route.defaults', '@route.internal'),
      association_target: Regexp.union('association.target.sort_by!', 'association(:user).target', 'return association.target if')
    }.freeze

    # What to change, per touch point, when a test fails on something its own
    # assertions do not word (an error, a secondary assertion).
    FIXES = {
      transaction_stack: 'adapt OpenTransaction.stack_of to where this Rails keeps the open transactions',
      transaction_joinable: 'adapt OpenTransaction#on (it skips non-joinable transactions)',
      transaction_state: 'adapt OpenTransaction#finished? / #rolled_back?',
      transaction_isolation_level: 'adapt OpenTransaction#snapshot_isolation?',
      transaction_add_record: 'adapt OpenTransaction::CommitHook and #after_commit / #before_commit / #after_end',
      open_transactions: 'adapt InvalidationBatch#claim',
      connection_pool_leases: 'adapt RLS.with_connection / .leased_connection and OpenTransaction.current',
      generated_attribute_methods: 'adapt MaskedAttributes.drop_generated_accessors and AliasAccess.accessor_module',
      attribute_methods_lock: 'adapt MaskedAttributes.with_attribute_methods_lock',
      subclass_attribute_methods: 'adapt MaskedAttributes.drop_generated_accessors',
      read_attribute_internal: 'adapt AliasAccess::AttributeAccessors.reader',
      write_attribute_internal: 'adapt AliasAccess::AttributeAccessors.writer',
      missing_attribute: 'adapt the masked getters and alias readers (they call it as Rails\' generated getters do)',
      dangerous_attribute_methods: 'adapt AliasAccess::TargetMethodAccessors::OwnMethods',
      alias_attribute_semantics: 'adapt AliasAccess.accessors (the version switch) and its accessor modules',
      alias_methods_module: 'adapt AliasAccess.accessor_module',
      aliases_by_attribute_name: 'adapt AliasAccess.declared_aliases / .registered_aliases',
      format_for_inspect: 'adapt MaskedAttributes#attribute_for_inspect',
      pretty_print: 'adapt MaskedAttributes#pretty_print',
      store_accessor_hooks: 'adapt MaskedAttributes::StoreAccess',
      serialization_hooks: 'adapt MaskedAttributes#attribute_names_for_serialization / #read_attribute_for_serialization',
      each_validator_reads: 'adapt MaskedAttributes::ValidationReads (EachValidatorWindow and read_attribute_for_validation)',
      trigger_destroy_callback: 'adapt RecordsAuditEvents#audit_row_deleted?',
      fanout_clear_cache: 'adapt Audit::Gate::FanoutHook / Gate.install!',
      notifier_writer: 'adapt Audit::Gate::NotifierHook',
      all_listeners_for: 'adapt Audit::Gate#heard_by',
      isolated_execution_state: 'adapt PermissionForge::ExecutionState (where its :execution slots are kept)',
      isolated_execution_state_context: 'adapt ExecutionState::RunHook (how it tells that a run ends where it started)',
      executor_register_hook: 'adapt ExecutionState.install! / RunHook (a snapshot when a run starts, put back when it completes)',
      write_multi_entries: 'adapt RailsCache.multi_write?',
      redis_write_multi_answer: 'adapt Cache::HandledErrors (how RailsCache#write_multi learns that the store did not write a batch)',
      local_cache: 'adapt RailsCache#read_fresh / #read_many',
      key_matcher_anchor: 'adapt UserKeys.entry_patterns and RailsCache#prefix_matcher',
      redis_store_kind: 'adapt RailsCache#redis_store? / #entry_matchers',
      default_scope: 'adapt PermissionScopedFindable / AutoPermissionScoping (default_scope)',
      find_by_override: 'adapt the find_by / find_by! override in PermissionScopedFindable',
      counter_updates: 'refuse the new counter write path in AuditEvent (InsertOnly covers the class and its relations)',
      relation_delegate_class: 'adapt AuditEvent (InsertOnly on the relation class)',
      process_action_callbacks: 'adapt ControllerActions.guarded?',
      arel_grouping: 'adapt Operators::Registry#grouped',
      arel_between: 'adapt Operators::Registry (between) and the RLS operator SQL',
      arel_matches: 'adapt Operators::Registry (LIKE operators)',
      arel_named_function: 'adapt PermissionSetUser.last_reviewed_column',
      schema_cache: 'adapt Operators::RuleColumn.on',
      association_join_checks: 'adapt Operators::RulePath#through / #joined_class to what Associations::JoinDependency#build ' \
                               'checks before it joins (a path it raises for must stay broken, one it joins followed)',
      preloader: 'adapt PermissionHashBuilder#preload',
      sandbox: 'adapt OpenTransaction.sandbox?',
      generator_commands: 'adapt BootChecks.generator_running? (GENERATOR_COMMANDS: what `bin/rails generate` loads before it boots)',
      journey_route: 'adapt Admin::ControllerCatalog::RoutedAction',
      association_target: 'adapt PermissionHashBuilder.sorted (and PermissionSetUser#assigned_users, RecordsAuditEvents#audit_associated)'
    }.freeze

    # Marks a failure message as a canary's.
    MARK = '[Rails internals canary:'

    class << self
      # @return [Array<String>] "path:line" of every line that uses the touch point
      def locations(key)
        needle = TOUCH_POINTS.fetch(key)
        sources.flat_map do |path, lines|
          lines.each_with_index.filter_map do |line, index|
            next if line.lstrip.start_with?('#')

            "#{path}:#{index + 1}" if needle.is_a?(Regexp) ? line.match?(needle) : line.include?(needle)
          end
        end
      end

      def sources
        @sources ||= Dir[File.join(ROOT, '{lib,app}/**/*.rb')].to_h do |path|
          [path.delete_prefix("#{ROOT}/"), File.readlines(path)]
        end
      end

      def versions
        "ActiveRecord #{ActiveRecord.version}, ActiveSupport #{ActiveSupport.version}"
      end
    end

    # Shared by both test classes.
    module Helpers
      def self.included(base)
        base.extend(ClassMethods)
      end

      # `canary_test :key, 'name' do … end`: a test of one touch point. Any
      # failure or error in it reads as that canary's (secondary assertions
      # and a Rails that raises instead of answering included).
      module ClassMethods
        def canary_test(key, name, &block)
          raise ArgumentError, "unknown touch point #{key}" unless TOUCH_POINTS.key?(key)

          test(name) { watching(key) { instance_exec(&block) } }
        end
      end

      private

      def watching(key)
        yield
      rescue Minitest::Skip
        raise
      rescue Minitest::Assertion => e
        raise if e.message.include?(MARK)

        reraise_as_canary(key, e.message.strip, e)
      rescue StandardError, SystemStackError => e
        reraise_as_canary(key, "#{e.class}: #{e.message.to_s.lines.first&.strip}", e)
      end

      def reraise_as_canary(key, change, error)
        raise Minitest::Assertion, canary(key, change, FIXES.fetch(key)), error.backtrace
      end

      # Whether a method can be called with exactly `count` positional
      # arguments (the gem's calls), whatever optional ones Rails adds.
      def accepts_positional?(method, count)
        kinds = method.parameters.map(&:first)
        required = kinds.count(:req)
        required <= count && (kinds.include?(:rest) || required + kinds.count(:opt) >= count)
      end

      # The failure message: which Rails, what changed, who relies on it, what to do.
      def canary(key, change, fix)
        where = RailsInternalsCanary.locations(key)
        "\n#{MARK} #{key}] on #{RailsInternalsCanary.versions}\n" \
          "What changed: #{change}\n" \
          "Relied on at: #{where.empty? ? '(nowhere any more — delete this canary)' : where.join(', ')}\n" \
          "What to change: #{fix}\n"
      end

      # A model of its own on the canary table, named (Rails needs a name for
      # some of what is asked here) and thrown away after the test.
      def canary_model(name = 'PfCanaryModel', parent: ApplicationRecord, &block)
        Class.new(parent) do
          self.table_name = 'pf_canary_records' if parent == ApplicationRecord
          define_singleton_method(:name) { name }
          class_eval(&block) if block
        end
      end

      def pool
        ActiveRecord::Base.connection_pool
      end

      # The calling thread's connection, kept (lease_connection from 7.2).
      def leased_connection
        pool.respond_to?(:lease_connection) ? pool.lease_connection : pool.connection
      end

      def transaction_stack(connection)
        connection.transaction_manager.instance_variable_get(:@stack)
      end
    end

    # A CommitHook (the block OpenTransaction enlists in a transaction in the
    # place of a record) that writes down every call Rails makes to it, with
    # its arguments and how many transactions were open at the time, before
    # the gem's own method runs with exactly those arguments.
    class RecordingCommitHook < PermissionForge::OpenTransaction::CommitHook
      def initialize(log, connection, name, raise_in: nil)
        @log = log
        @connection = connection
        @name = name
        @raise_in = raise_in
        super(after: -> { log << [name, :after_block] },
              before: -> { log << [name, :before_block] },
              rollback: -> { log << [name, :rollback_block] })
      end

      def trigger_transactional_callbacks?
        @log << [@name, :trigger_transactional_callbacks?]
        super
      end

      def before_committed!(*args, **kwargs)
        note(:before_committed!, args, kwargs)
        raise "#{@name} refused the commit" if @raise_in == :before_committed!

        super
      end

      def committed!(*args, **kwargs)
        note(:committed!, args, kwargs)
        super
        raise "#{@name} after_commit failed" if @raise_in == :committed!
      end

      def rolledback!(*args, **kwargs)
        note(:rolledback!, args, kwargs)
        super
      end

      private

      def note(call, args, kwargs)
        @log << [@name, call, { args: args, kwargs: kwargs, open: @connection.open_transactions }]
      end
    end
  end

  # The canaries that need real transactions — BEGIN and COMMIT on the
  # connection, as in production — and not the transaction Rails wraps a test
  # in. Nothing here writes a row.
  class RailsInternalsCanaryTransactionsTest < ActiveSupport::TestCase
    include RailsInternalsCanary::Helpers

    self.use_transactional_tests = false

    def calls(log, name, call)
      log.select { |entry| entry[0] == name && entry[1] == call }
    end

    canary_test :transaction_stack, 'TransactionManager @stack: an Array of the open transactions, outermost first' do
      connection = leased_connection
      manager = connection.transaction_manager

      assert manager.instance_variable_defined?(:@stack), canary(
        :transaction_stack, "#{manager.class} has no @stack any more",
        'find where this Rails keeps the open transactions and read it in OpenTransaction.stack_of — until then the ' \
        'gem raises ConfigurationError on every OpenTransaction.current (it never guesses from the innermost one)'
      )

      ActiveRecord::Base.transaction do
        outer = connection.current_transaction
        ActiveRecord::Base.transaction(requires_new: true) do
          inner = connection.current_transaction
          stack = transaction_stack(connection)

          assert_kind_of Array, stack, canary(:transaction_stack, "@stack is a #{stack.class}", 'adapt OpenTransaction.stack_of to the new shape')
          assert_equal [outer, inner].map(&:object_id), stack.map(&:object_id), canary(
            :transaction_stack, '@stack does not list the open transactions outermost first',
            'OpenTransaction#on takes stack.first / the first joinable one as the outermost: adapt it to the new order'
          )
          assert_equal stack.size, connection.open_transactions, canary(
            :open_transactions, 'open_transactions no longer counts the transactions on the stack',
            'InvalidationBatch#claim compares open_transactions between the save and the after_commit: find another depth'
          )
        end
      end
    end

    canary_test :transaction_joinable, 'Transaction#joinable?: false for a transaction opened joinable: false, true for one opened inside it' do
      connection = leased_connection
      ActiveRecord::Base.transaction(joinable: false) do
        wrapper = connection.current_transaction
        ActiveRecord::Base.transaction(requires_new: true) do
          inner = connection.current_transaction

          assert_equal [false, true], [wrapper.joinable?, inner.joinable?], canary(
            :transaction_joinable, 'joinable? no longer tells the wrapping (test / before_all) transaction from the ones opened inside it',
            'OpenTransaction#on skips non-joinable transactions to find the one that counts: find what marks them now'
          )
        end
      end
    end

    canary_test :transaction_state,
                'Transaction#state: finalized? after a commit, rolledback? also for a released savepoint whose parent rolls back' do
      connection = leased_connection
      released = outer = nil
      ActiveRecord::Base.transaction do
        outer = connection.current_transaction
        ActiveRecord::Base.transaction(requires_new: true) { released = connection.current_transaction }

        assert released.state.finalized?, canary(:transaction_state, 'a released savepoint is not finalized?', 'adapt OpenTransaction#finished?')
        assert_not released.state.rolledback?
        raise ActiveRecord::Rollback
      end

      assert outer.state.finalized?, canary(
        :transaction_state, 'a transaction that ended is not state.finalized?',
        'OpenTransaction#finished? reads state.finalized?: find what says a transaction ended'
      )
      assert released.state.rolledback?, canary(
        :transaction_state, 'rolling a transaction back no longer marks the savepoints released inside it as rolled back',
        'OpenTransaction#rolled_back? asks the innermost transaction: walk up to the transactions around it instead'
      )
    end

    canary_test :transaction_isolation_level, 'Transaction#isolation_level: the level the transaction was opened with, nil without one' do
      connection = leased_connection
      # SQLite accepts only read_uncommitted, and refuses any other level
      # once the transaction is sent (it is lazy, but a test before this one
      # may have left the connection materializing at once).
      level = connection.adapter_name.match?(/sqlite/i) ? :read_uncommitted : :serializable
      # Only the transaction object is asked: keep it lazy (never sent).
      connection.transaction_manager.enable_lazy_transactions!
      levels = ActiveRecord::Base.transaction(isolation: level) { transaction_stack(connection).map(&:isolation_level) }
      plain = ActiveRecord::Base.transaction { transaction_stack(connection).map(&:isolation_level) }

      assert_equal [[level], [nil]], [levels, plain], canary(
        :transaction_isolation_level, 'isolation_level does not report the level a transaction was opened with',
        'OpenTransaction#snapshot_isolation? decides from it whether a PostgreSQL transaction reads from a snapshot ' \
        '(snapshot_transactions = :auto): find where the level is kept now'
      )
    end

    canary_test :transaction_add_record, 'Transaction#add_record: before_committed! before the COMMIT, committed! once after it, in order' do
      connection = leased_connection
      log = []
      ActiveRecord::Base.transaction do
        connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :first))
        connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :second))
      end

      before = calls(log, :first, :before_committed!)
      committed = calls(log, :first, :committed!)
      assert_equal 1, before.size, canary(:transaction_add_record, "before_committed! was called #{before.size} times", 'adapt OpenTransaction::CommitHook#before_committed!')
      assert_equal 1, before.first[2][:open], canary(
        :transaction_add_record, 'before_committed! no longer runs while the transaction is still open',
        'OpenTransaction#before_commit (the audit guard that keeps an unaudited change from committing) needs a hook that runs before the COMMIT'
      )
      assert_equal 1, committed.size, canary(:transaction_add_record, "committed! was called #{committed.size} times", 'adapt OpenTransaction::CommitHook#committed!')
      assert_equal 0, committed.first[2][:open], canary(
        :transaction_add_record, 'committed! runs before the transaction is off the stack',
        'OpenTransaction#after_commit promises the block runs once everybody can see the rows: find the new after-COMMIT hook'
      )
      blocks = log.select { |entry| entry[0] == :first && entry[1].end_with?('_block') }.map { |entry| entry[1] }
      assert_equal %i[before_block after_block], blocks
      order = %i[first second].map { |name| log.index { |entry| entry[0] == name && entry[1] == :committed! } }
      assert_equal order.sort, order,
                   canary(:transaction_add_record, 'records are no longer committed in the order they were added', 'check the order Audit relies on')
      assert_not_empty calls(log, :first, :trigger_transactional_callbacks?), canary(
        :transaction_add_record, 'Rails no longer asks a record trigger_transactional_callbacks?',
        'check which method now decides whether a record gets committed!; CommitHook must answer it'
      )
    end

    canary_test :transaction_add_record, 'Transaction#add_record: a released savepoint hands its records to the transaction around it' do
      connection = leased_connection
      log = []
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :hook))
        end

        assert_empty calls(log, :hook, :committed!), canary(
          :transaction_add_record, 'a record of a released savepoint is committed! before the outermost transaction commits',
          'OpenTransaction#after_commit would run before the rows are visible: keep the block until the real COMMIT'
        )
      end

      assert_equal 1, calls(log, :hook, :committed!).size, canary(
        :transaction_add_record, 'a record of a released savepoint is not committed! with the outermost transaction',
        'Rails stopped moving records to the parent transaction: OpenTransaction must enlist the hook in the outermost one'
      )
    end

    canary_test :transaction_add_record, 'Transaction#add_record: a savepoint that rolls back calls rolledback! (keywords) and never committed!' do
      connection = leased_connection
      log = []
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :hook))
          raise ActiveRecord::Rollback
        end
      end

      rolledback = calls(log, :hook, :rolledback!)
      assert_not_empty rolledback,
                       canary(:transaction_add_record, 'a rolled-back savepoint does not call rolledback! on its records',
                              'adapt OpenTransaction#after_end')
      shapes = rolledback.map { |entry| entry[2].slice(:args, :kwargs) }
      keywords_only = shapes.all? { |shape| shape[:args].empty? }
      assert keywords_only, canary(
        :transaction_add_record, "rolledback! is now called with positional arguments: #{shapes.inspect}",
        'CommitHook#rolledback!(*, **) accepts them, but check what they mean'
      )
      assert_empty calls(log, :hook, :committed!)
      assert_equal 1, log.count { |entry| entry[1] == :rollback_block },
                   'the gem runs its rollback block once, however often Rails calls rolledback!'
    end

    canary_test :transaction_add_record, 'Transaction#add_record: committed! still reaches the other records when one of them raises' do
      connection = leased_connection
      log = []
      error = assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :failing, raise_in: :committed!))
          connection.current_transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :next))
        end
      end

      assert_match 'after_commit failed', error.message
      assert_equal 1, calls(log, :next, :after_block).size, canary(
        :transaction_add_record, 'a record whose commit callback raises keeps the records after it from being committed!',
        'that is the reason OpenTransaction does not use ActiveRecord::Transaction#after_commit: find another hook that always runs'
      )
    end

    canary_test :transaction_add_record, 'Transaction#add_record: before_committed! that raises fails the commit and rolls the transaction back' do
      connection = leased_connection
      log = []
      transaction = nil
      assert_raises(RuntimeError) do
        ActiveRecord::Base.transaction do
          transaction = connection.current_transaction
          transaction.add_record(RailsInternalsCanary::RecordingCommitHook.new(log, connection, :guard, raise_in: :before_committed!))
        end
      end

      assert transaction.state.rolledback?, canary(
        :transaction_add_record, 'an error in before_committed! no longer rolls the transaction back',
        'OpenTransaction#before_commit is how a change whose audit event failed is kept from committing: find another way'
      )
      assert_empty calls(log, :guard, :committed!)
    end

    canary_test :connection_pool_leases, 'ConnectionPool#with_connection / lease_connection: a connection for a block, or one the thread keeps' do
      result = Thread.new do
        Thread.current.report_on_exception = false
        held_at_start = pool.active_connection?
        borrowed = pool.with_connection { |connection| connection }
        held_after_block = pool.active_connection?
        kept = leased_connection
        [held_at_start, borrowed, held_after_block, kept, pool.active_connection?, pool.with_connection { |connection| connection }]
      ensure
        pool.release_connection
      end.value
      held_at_start, borrowed, held_after_block, kept, held_after_lease, reused = result

      assert_not held_at_start
      assert borrowed, canary(:connection_pool_leases, 'with_connection did not yield a connection', 'adapt RLS.with_connection')
      assert_not held_after_block, canary(
        :connection_pool_leases, 'with_connection keeps the connection leased to the thread after the block',
        'RLS (and OpenTransaction.current) count on with_connection giving back a connection the thread did not hold'
      )
      assert held_after_lease,
             canary(:connection_pool_leases, 'the leased connection is not kept by the thread', 'RLS.set_user! needs a connection the request keeps')
      assert_same kept, reused, canary(
        :connection_pool_leases, 'with_connection does not use the connection the thread already holds',
        'RLS.with_user runs its block on the connection it set the user on; OpenTransaction.current must see the caller\'s transaction'
      )
    end
  end

  # Everything else: attribute methods, inspection, serialization, stores,
  # notifications, caches, scoping, Arel. Inside the transaction Rails wraps
  # each test in.
  class RailsInternalsCanaryTest < ActiveSupport::TestCase
    include RailsInternalsCanary::Helpers

    test 'every touch point is still used: each TOUCH_POINTS entry names code in lib/ or app/' do
      unused = RailsInternalsCanary::TOUCH_POINTS.keys.select { |key| RailsInternalsCanary.locations(key).empty? }

      assert_empty unused, "The gem no longer contains the code these canaries watch: #{unused.join(', ')}. " \
                           'If the reliance on the Rails internal is gone, delete its canary test and TOUCH_POINTS ' \
                           'entry; if the code only moved or was reworded, update the TOUCH_POINTS needle.'
    end

    # --- attribute methods --------------------------------------------------------------------------------

    canary_test :generated_attribute_methods, 'generated_attribute_methods: a private class method returning the module the column methods are in' do
      model = canary_model
      model.define_attribute_methods

      assert model.private_methods.include?(:generated_attribute_methods) || model.respond_to?(:generated_attribute_methods, true), canary(
        :generated_attribute_methods, 'generated_attribute_methods is gone',
        'MaskedAttributes.drop_generated_accessors and AliasAccess.accessor_module need the module Rails generates attribute methods into'
      )
      generated = model.send(:generated_attribute_methods)
      assert_kind_of ActiveRecord::AttributeMethods::GeneratedAttributeMethods, generated, canary(
        :generated_attribute_methods, "generated_attribute_methods is a #{generated.class}",
        'AliasAccess::TargetMethodAccessors tells Rails-generated methods apart by that class'
      )
      assert_includes model.ancestors, generated
      assert_equal generated, model.instance_method(:email).owner, canary(
        :generated_attribute_methods, 'the column reader is not defined in generated_attribute_methods',
        'find where Rails defines column methods now; MaskedAttributes removes them from there'
      )
    end

    canary_test :attribute_methods_lock,
                'GeneratedAttributeMethods::LOCK (7.2+) / the module\'s own lock (7.1): the lock attribute methods are generated under' do
      model = canary_model
      generated = model.send(:generated_attribute_methods)
      started = Queue.new
      waited = nil
      generator = nil
      # The gem's own choice of lock, held while another thread generates.
      PermissionForge::Concerns::MaskedAttributes.send(:with_attribute_methods_lock, generated) do
        generator = Thread.new do
          Thread.current.report_on_exception = false
          started << true
          model.define_attribute_methods
          true
        end
        started.pop
        # The generator either blocks on the lock (it sleeps) or, if Rails
        # takes another lock, runs to its end. No clock: Thread.pass until one
        # of the two.
        Thread.pass while generator.status == 'run'
        waited = generator.status == 'sleep'
      end

      assert waited, canary(
        :attribute_methods_lock, 'define_attribute_methods does not wait for the lock the gem takes',
        'MaskedAttributes.with_attribute_methods_lock must take the lock Rails generates attribute methods under ' \
        "(GeneratedAttributeMethods::LOCK from 7.2, the generated module's own on 7.1): find the new one"
      )
      assert generator.value, canary(:attribute_methods_lock, 'define_attribute_methods failed once the lock was free', RailsInternalsCanary::FIXES[:attribute_methods_lock])
    end

    canary_test :subclass_attribute_methods,
                'subclass attribute methods: a subclass generates its own unless its parent defines the method outside a generated module' do
      parent = canary_model('PfCanaryParent')
      early_child = canary_model('PfCanaryEarlyChild', parent: parent)
      early_child.define_attribute_methods

      assert early_child.send(:generated_attribute_methods).method_defined?(:email, false), canary(
        :subclass_attribute_methods, 'a subclass no longer generates column methods of its own',
        'MaskedAttributes.drop_generated_accessors may no longer be needed: check the subclass tests'
      )

      readers = Module.new { def email = 'parent reader' }
      parent.prepend(readers)
      late_child = canary_model('PfCanaryLateChild', parent: parent)
      late_child.define_attribute_methods

      assert_not late_child.send(:generated_attribute_methods).method_defined?(:email, false), canary(
        :subclass_attribute_methods, 'a subclass generates its own reader although its parent defines one outside a generated module',
        'a subclass loaded after MaskedAttributes would skip the masked reader: drop its generated methods as for an early one'
      )

      PermissionForge::Concerns::MaskedAttributes.drop_generated_accessors(early_child, readers)
      assert_equal 'parent reader', early_child.new(email: 'raw').email, canary(
        :subclass_attribute_methods, 'removing the method from the subclass\'s generated module does not let the parent\'s reader through',
        'adapt MaskedAttributes.drop_generated_accessors'
      )
    end

    canary_test :read_attribute_internal,
                '_read_attribute(name) { |missing| }: the stored value past any reader, the block for an attribute not loaded' do
      model = canary_model { def email = 'own reader' }
      record = model.new(email: 'stored')

      assert_equal 'stored', record._read_attribute('email'), canary(
        :read_attribute_internal, '_read_attribute goes through the model\'s reader or is gone',
        'AliasAccess::AttributeAccessors reads an alias\'s target with it, as Rails\' own alias reader does: use what Rails uses now'
      )
      partial = model.instantiate('id' => 1)
      assert_equal 'missing email', partial._read_attribute('email') { |name| "missing #{name}" }, canary(
        :read_attribute_internal, '_read_attribute does not yield the name of an attribute that was not loaded',
        'the alias reader must raise MissingAttributeError for select(:id), as plain Rails does'
      )
    end

    canary_test :write_attribute_internal, '_write_attribute(name, value): writes past any setter and marks the attribute changed' do
      model = canary_model { define_method(:email=) { |_value| raise 'own setter' } }
      record = model.new
      record._write_attribute('email', 'written')

      assert_equal ['written', true], [record._read_attribute('email'), record.email_changed?], canary(
        :write_attribute_internal, '_write_attribute no longer writes the attribute (dirty-tracked) past the setter',
        'AliasAccess::AttributeAccessors writes an alias\'s target with it, as Rails\' own alias writer does'
      )
    end

    canary_test :missing_attribute, 'missing_attribute(name, stack): private, raises ActiveModel::MissingAttributeError naming the attribute' do
      record = PfCanaryRecord.instantiate('id' => 1)

      assert PfCanaryRecord.private_method_defined?(:missing_attribute), canary(
        :missing_attribute, 'missing_attribute is gone or public',
        'the masked getters call it the way Rails\' generated getters do: use what they call now'
      )
      method = PfCanaryRecord.instance_method(:missing_attribute)
      assert accepts_positional?(method, 2),
             canary(:missing_attribute, "missing_attribute takes #{method.parameters.inspect}", 'adapt the calls (name, caller)')
      error = assert_raises(ActiveModel::MissingAttributeError) { record.send(:missing_attribute, 'email', caller) }
      assert_includes error.message, 'email'
      assert_raises(ActiveModel::MissingAttributeError) { record.email }
    end

    canary_test :dangerous_attribute_methods, 'AttributeMethods.dangerous_attribute_methods: the method names of ActiveRecord::Base, as Strings' do
      names = ActiveRecord::AttributeMethods.dangerous_attribute_methods

      assert names.respond_to?(:include?), canary(:dangerous_attribute_methods, "it is a #{names.class}", 'adapt AliasAccess::TargetMethodAccessors::OwnMethods')
      listed = %w[save destroy reload].all? { |name| names.include?(name) }
      assert listed, canary(
        :dangerous_attribute_methods, 'it no longer lists ActiveRecord::Base methods by String name',
        'Rails 7.1 alias semantics (OwnMethods#defined_by_the_model?) ask it with a String'
      )
      assert_not names.include?('email')
    end

    canary_test :alias_attribute_semantics,
                'alias_attribute semantics: 7.2+ read the attribute past the model\'s reader; 7.1 call the model\'s reader' do
      model = ActiveRecord.deprecator.silence do
        canary_model do
          def email = 'own reader'
          alias_attribute :mail, :email
        end
      end
      value = ActiveRecord.deprecator.silence { model.new(email: 'stored').mail }
      selected = PermissionForge::Concerns::MaskedAttributes::AliasAccess.send(:accessors)

      if ActiveRecord.version < Gem::Version.new('7.2')
        assert_equal 'own reader', value,
                     canary(:alias_attribute_semantics, 'Rails 7.1 aliases stopped calling the model\'s own reader', 'adapt TargetMethodAccessors')
        assert_equal PermissionForge::Concerns::MaskedAttributes::AliasAccess::TargetMethodAccessors, selected
      else
        assert_equal 'stored', value, canary(
          :alias_attribute_semantics, "this Rails's alias reader calls the model's reader of the target",
          'AliasAccess picks AttributeAccessors (read the attribute itself) from 7.2 on: use TargetMethodAccessors for this version'
        )
        assert_equal PermissionForge::Concerns::MaskedAttributes::AliasAccess::AttributeAccessors, selected
      end
    end

    canary_test :alias_methods_module,
                'alias methods module: Rails defines an alias\'s methods in the declaring class\'s generated module; a module prepended to it wins' do
      model = canary_model { alias_attribute :mail, :email }
      child = canary_model('PfCanaryAliasChild', parent: model)
      model.define_attribute_methods
      child.define_attribute_methods
      generated = model.send(:generated_attribute_methods)

      assert generated.method_defined?(:mail, false), canary(
        :alias_methods_module, 'the alias reader is not in the generated module of the class that declares the alias',
        'AliasAccess.accessor_module prepends the guarded accessors to that module: find where alias methods live now'
      )
      assert_not child.send(:generated_attribute_methods).method_defined?(:mail, false)

      generated.prepend(Module.new { def mail = 'guarded' })
      assert_equal %w[guarded guarded], [model.new(email: 'x').mail, child.new(email: 'x').mail], canary(
        :alias_methods_module, 'a module prepended to the generated module is not found before Rails\' alias reader',
        'move AliasAccess\'s accessors to where they are found first'
      )
    end

    canary_test :aliases_by_attribute_name, 'aliases_by_attribute_name: each class\'s own registry of the aliases it declares, by target' do
      model = canary_model { alias_attribute :mail, :email }
      child = canary_model('PfCanaryAliasChild', parent: model) { alias_attribute :title, :name }

      assert child.respond_to?(:aliases_by_attribute_name), canary(
        :aliases_by_attribute_name, 'aliases_by_attribute_name is gone',
        'AliasAccess.declared_aliases falls back to comparing attribute_aliases with the superclass: check that fallback is right'
      )
      assert_equal({ 'email' => ['mail'] }, model.aliases_by_attribute_name.to_h.except('id'))
      own = child.aliases_by_attribute_name.to_h.except('id')
      message = canary(
        :aliases_by_attribute_name, 'a subclass\'s registry is no longer its own (it lists the parent\'s aliases)',
        'AliasAccess.registered_aliases would define accessors in the wrong class'
      )
      assert_equal({ 'name' => ['title'] }, own, message)
      assert_equal({ 'mail' => 'email', 'title' => 'name' }, child.attribute_aliases.slice('mail', 'title'))
    end

    # --- inspection ---------------------------------------------------------------------------------------

    canary_test :format_for_inspect, 'format_for_inspect(name, value): private; what inspect prints for a value, filter_attributes applied' do
      model = canary_model { self.filter_attributes = [:email] }
      record = model.new

      assert model.private_method_defined?(:format_for_inspect), canary(
        :format_for_inspect, 'format_for_inspect is gone',
        'MaskedAttributes#attribute_for_inspect formats the masked value with it (a failure shows the hidden value, ' \
        'never the stored one): use what attribute_for_inspect uses now'
      )
      method = model.instance_method(:format_for_inspect)
      assert accepts_positional?(method, 2),
             canary(:format_for_inspect, "format_for_inspect takes #{method.parameters.inspect}", 'adapt the call (name, value)')
      formatted = [record.send(:format_for_inspect, 'name', 'short'), record.send(:format_for_inspect, 'email', 'secret')]
      assert_equal ['"short"', '[FILTERED]'], formatted, canary(
        :format_for_inspect, "format_for_inspect formats a value as #{formatted.inspect} (no quotes, or filter_attributes left out)",
        'MaskedAttributes#attribute_for_inspect relies on it to print the masked value as Rails prints values'
      )
    end

    canary_test :pretty_print,
                'inspect and pretty_print: inspect lists attribute_for_inspect; pretty_print does from 7.2 (7.1: the gem\'s own listing)' do
      model = canary_model { def attribute_for_inspect(name) = "<#{name}>" }
      model.attributes_for_inspect = :all if model.respond_to?(:attributes_for_inspect=)
      record = model.new(name: 'raw name')

      assert_includes record.inspect, 'name: <name>', canary(
        :format_for_inspect, 'inspect no longer prints attribute_for_inspect',
        'MaskedAttributes#attribute_for_inspect keeps masked values out of logs: hook what inspect prints now'
      )
      printed = PP.pp(record, +'')
      if ActiveRecord.gem_version < Gem::Version.new('7.2')
        assert_includes printed, 'raw name', 'Rails 7.1 pretty_print reads the raw attribute (the reason for the 7.1 re-implementation)'
        assert model.private_method_defined?(:custom_inspect_method_defined?), canary(
          :pretty_print, 'custom_inspect_method_defined? is gone', 'adapt MaskedAttributes#pretty_print (7.1)'
        )
        assert record.instance_variable_defined?(:@attributes),
               canary(:pretty_print, 'records have no @attributes', 'adapt MaskedAttributes#pretty_print (7.1)')
        assert record._has_attribute?('name'), canary(:pretty_print, '_has_attribute? is gone', 'adapt MaskedAttributes#pretty_print (7.1)')
      else
        assert_includes printed, '<name>', canary(
          :pretty_print, 'pretty_print no longer prints attribute_for_inspect',
          'masked values reach pp/console output: re-implement pretty_print for this version (see the 7.1 branch in MaskedAttributes)'
        )
        assert_not_includes printed, 'raw name'
      end
    end

    # --- stores and serialization -------------------------------------------------------------------------

    canary_test :store_accessor_hooks,
                'read_store_attribute / write_store_attribute: private; store accessors call them and reach the column through its getter' do
      log = []
      model = canary_model { store :prefs, accessors: [:theme], coder: JSON }
      model.prepend(Module.new do
        define_method(:prefs) { (log << :getter) && super() }
        define_method(:read_store_attribute) { |attribute, key| (log << [:read, attribute.to_s, key.to_s]) && super(attribute, key) }
        define_method(:write_store_attribute) do |attribute, key, value|
          log << [:write, attribute.to_s, key.to_s]
          super(attribute, key, value).tap { log << :written }
        end
        private :read_store_attribute, :write_store_attribute
      end)
      record = model.new
      record.theme = 'dark'
      written = log.dup
      log.clear

      assert model.private_method_defined?(:read_store_attribute) && model.private_method_defined?(:write_store_attribute)
      assert_equal 'dark', record.theme
      assert_equal [[:read, 'prefs', 'theme'], :getter], log.uniq, canary(
        :store_accessor_hooks, 'a store accessor no longer reads through read_store_attribute and the column getter',
        'MaskedAttributes::StoreAccess hides a key of a hidden store column there: hook what the accessor calls now'
      )
      assert_equal [:write, 'prefs', 'theme'], written.first
      assert_includes written[1..written.index(:written)], :getter, canary(
        :store_accessor_hooks, 'write_store_attribute does not reach the stored hash through the column getter',
        'StoreAccess opens a raw window on the column for the write: adapt it'
      )
    end

    canary_test :each_validator_reads,
                'EachValidator#validate: run_validations! runs it; it reads read_attribute_for_validation, numericality then read_attribute' do
      model = canary_model
      reads = []
      model.prepend(Module.new do
        define_method(:read_attribute_for_validation) { |name| (reads << [:for_validation, name.to_s]) && super(name) }
        define_method(:read_attribute) { |name, &block| (reads << [:read_attribute, name.to_s]) && super(name, &block) }
        define_method(:run_validations!) { (reads << [:run_validations!]) && super() }
        private :run_validations!
      end)
      model.validates :parent_id, numericality: { less_than: 10 }
      record = model.create!(parent_id: 5)
      reads.clear
      model.find(record.id).valid?

      assert ActiveModel::EachValidator.method_defined?(:validate), canary(
        :each_validator_reads, 'EachValidator#validate is gone', 'hook what runs an EachValidator for a record now'
      )
      assert_equal [[:run_validations!], [:for_validation, 'parent_id'], [:read_attribute, 'parent_id']],
                   reads.reject { |entry| entry.last == 'id' }.first(3), canary(
                     :each_validator_reads, 'the validators read the attribute differently',
                     'make ValidationReads keep the stored-value read open for what they read now'
                   )
    end

    canary_test :serialization_hooks,
                'attribute_names_for_serialization / read_attribute_for_serialization: serializable_hash asks them for names and values' do
      model = canary_model
      model.prepend(Module.new do
        def attribute_names_for_serialization = super - ['email']
        def read_attribute_for_serialization(name) = name == 'name' ? 'via hook' : super
        private :attribute_names_for_serialization
      end)
      json = model.new(name: 'raw', email: 'secret').as_json

      assert model.private_method_defined?(:attribute_names_for_serialization), canary(
        :serialization_hooks, 'attribute_names_for_serialization is gone or public', 'adapt MaskedAttributes#attribute_names_for_serialization'
      )
      assert_not json.key?('email'), canary(
        :serialization_hooks, 'serializable_hash no longer takes its names from attribute_names_for_serialization',
        'hidden columns would be serialized: hook what serializable_hash uses now'
      )
      assert_equal 'via hook', json['name'], canary(
        :serialization_hooks, 'serializable_hash no longer reads values through read_attribute_for_serialization',
        'masked values would be serialized raw: hook what serializable_hash reads with now'
      )
    end

    canary_test :trigger_destroy_callback,
                '_trigger_destroy_callback: private; true in after_destroy when the DELETE removed the row, false when it was gone' do
      seen = []
      model = canary_model do
        after_destroy { seen << (respond_to?(:_trigger_destroy_callback, true) ? send(:_trigger_destroy_callback) : :gone) }
      end
      first = model.create!(name: 'row')
      second = model.find(first.id)
      first.destroy
      second.destroy

      assert first.respond_to?(:_trigger_destroy_callback, true), canary(
        :trigger_destroy_callback, '_trigger_destroy_callback is gone',
        'RecordsAuditEvents#audit_row_deleted? then writes a destroy event for a DELETE that hit no row: ' \
        'find what Rails keeps for its own commit callbacks'
      )
      assert_equal [true, false], seen.map { |value| value ? true : false }, canary(
        :trigger_destroy_callback, "_trigger_destroy_callback answered #{seen.inspect}",
        'RecordsAuditEvents#audit_row_deleted? must tell a DELETE that removed the row from one that found nothing'
      )
    end

    # --- notifications --------------------------------------------------------------------------------------

    canary_test :fanout_clear_cache, 'Notifications::Fanout#clear_cache: public, called by every subscribe and unsubscribe' do
      fanout = ActiveSupport::Notifications::Fanout.new
      cleared = []
      fanout.singleton_class.prepend(Module.new { define_method(:clear_cache) { |*args| (cleared << args) && super(*args) } })

      steps = []
      named = fanout.subscribe('pf.canary') { nil }
      steps << cleared.size
      pattern = fanout.subscribe(/pf\.canary/) { nil }
      steps << cleared.size
      fanout.unsubscribe(named)
      steps << cleared.size
      fanout.unsubscribe(pattern)
      steps << cleared.size

      assert ActiveSupport::Notifications::Fanout.method_defined?(:clear_cache), canary(
        :fanout_clear_cache, 'Fanout#clear_cache is gone or private',
        'Audit::Gate.install! then leaves the hook out and asks the notifier on every check (correct, slower): ' \
        'hook what invalidates the listener cache now'
      )
      assert_equal steps.uniq, steps, canary(
        :fanout_clear_cache, "not every subscribe/unsubscribe calls clear_cache (calls after each step: #{steps.inspect})",
        'Audit::Gate would keep an answer after a subscriber came or went: a runtime audit event nobody hears, or one dropped'
      )
      assert_operator steps.first, :>=, 1
      assert_includes ActiveSupport::Notifications::Fanout.ancestors, PermissionForge::Audit::Gate::FanoutHook
    end

    canary_test :notifier_writer, 'ActiveSupport::Notifications.notifier=: a singleton writer the gem prepends to' do
      notifications = ActiveSupport::Notifications.singleton_class

      assert notifications.method_defined?(:notifier=), canary(
        :notifier_writer, 'ActiveSupport::Notifications.notifier= is gone',
        'Audit::Gate::NotifierHook notices a new notifier there: hook what replaces the notifier now'
      )
      before = PermissionForge::Audit::Gate.generation
      notifier = ActiveSupport::Notifications.notifier
      ActiveSupport::Notifications.notifier = notifier
      assert_operator PermissionForge::Audit::Gate.generation, :>, before, canary(
        :notifier_writer, 'replacing the notifier does not go through the prepended notifier=',
        'Audit::Gate would keep answers made for the old notifier'
      )
      assert PermissionForge::Audit::Gate.tracking?(ActiveSupport::Notifications.notifier)
    end

    canary_test :all_listeners_for,
                'Notifications::Fanout#all_listeners_for: the listeners of a name, named and pattern ones, refreshed by a subscribe' do
      fanout = ActiveSupport::Notifications::Fanout.new
      first = Object.new.tap { |listener| def listener.call(*) = nil }
      second = Object.new.tap { |listener| def listener.call(*) = nil }
      fanout.subscribe('pf.canary', first)
      # As Audit::Gate#heard_by reads them: the subscriber behind a listener, or the listener itself.
      subscribers = ->(listeners) { listeners.map { |listener| listener.respond_to?(:delegate) ? listener.delegate : listener } }
      before = subscribers.call(fanout.all_listeners_for('pf.canary'))
      fanout.subscribe(/pf\.can/, second)
      after = subscribers.call(fanout.all_listeners_for('pf.canary'))

      assert_equal [[first], [first, second].sort_by(&:object_id)], [before, after.sort_by(&:object_id)], canary(
        :all_listeners_for, 'all_listeners_for no longer lists the listeners of a name (named and pattern subscribers)',
        'Audit::Gate#heard_by falls back to listening? (no direct path for the legacy hooks): adapt heard_by'
      )
    end

    # --- execution state ------------------------------------------------------------------------------------

    canary_test :isolated_execution_state, 'ActiveSupport::IsolatedExecutionState: [], []= and delete, one state per thread (or fiber)' do
      state = ActiveSupport::IsolatedExecutionState
      state[:pf_canary] = :here
      elsewhere = Thread.new { state[:pf_canary] }.value

      assert_equal [:here, nil], [state[:pf_canary], elsewhere], canary(
        :isolated_execution_state, 'IsolatedExecutionState no longer keeps a value per thread',
        'ExecutionState keeps its :execution slots there (the audit context, the invalidation batch, the cache failures): adapt it'
      )
      assert_includes %i[thread fiber], state.isolation_level
    ensure
      ActiveSupport::IsolatedExecutionState.delete(:pf_canary)
    end

    canary_test :isolated_execution_state_context,
                'IsolatedExecutionState.context: the thread under :thread isolation (a fiber of it included), the fiber under :fiber' do
      state = ActiveSupport::IsolatedExecutionState
      previous = state.isolation_level
      begin
        state.isolation_level = :thread
        thread_level = [state.context, Fiber.new { state.context }.resume]
        state.isolation_level = :fiber
        fiber_level = [state.context, Fiber.new { state.context }.resume]
      ensure
        state.isolation_level = previous
      end

      on_thread = thread_level.all? { |context| context.equal?(Thread.current) }
      assert on_thread, canary(
        :isolated_execution_state_context, 'under :thread, context is no longer the current thread (for every fiber of it)',
        'RunHook compares the context a run started on with the one it completes on: compare the thread instead'
      )
      assert fiber_level.first.equal?(Fiber.current) && !fiber_level.last.equal?(Fiber.current), canary(
        :isolated_execution_state_context, 'under :fiber, context is no longer the current fiber',
        'RunHook compares the context a run started on with the one it completes on: compare the fiber instead'
      )
    end

    canary_test :executor_register_hook,
                'Executor.register_hook: hook.run when a run starts, hook.complete(what run returned) when it ends, also on raise' do
      log = []
      hook = Object.new
      hook.define_singleton_method(:run) do
        log << :run
        :snapshot
      end
      hook.define_singleton_method(:complete) { |state| log << [:complete, state] }
      executor = Class.new(ActiveSupport::Executor)
      executor.register_hook(hook)

      executor.wrap { log << :block }
      assert_raises(RuntimeError) { executor.wrap { raise 'boom' } }

      assert_equal [:run, :block, %i[complete snapshot], :run, %i[complete snapshot]], log, canary(
        :executor_register_hook, 'register_hook no longer hands what run returned to complete (or no longer completes on raise)',
        'ExecutionState::RunHook puts back what it took when the run started: register a to_run / to_complete pair that ' \
        'keeps the snapshot itself'
      )
    end

    # --- caches -----------------------------------------------------------------------------------------------

    # Never connected. No connection pool: Rails 7.1/7.2 build theirs with an
    # argument connection_pool 3 no longer takes.
    def redis_store
      ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://127.0.0.1:1/15', pool: false)
    end

    canary_test :write_multi_entries,
                'Cache::Store#write_multi_entries: private, what write_multi writes through; only stores that batch override it' do
      batching = Class.new(ActiveSupport::Cache::MemoryStore) do
        define_singleton_method(:name) { 'PfCanaryBatchingStore' } # LocalCache (Rails main) names its key after the class
        attr_reader :batch

        private

        def write_multi_entries(entries, **options)
          @batch = entries
          super
        end
      end
      store = batching.new
      store.write_multi('a' => 1, 'b' => 2)

      assert ActiveSupport::Cache::Store.private_method_defined?(:write_multi_entries), canary(
        :write_multi_entries, 'Store#write_multi_entries is gone or public',
        'RailsCache.multi_write? (instance_method(:write_multi_entries).owner) raises NameError on every write_many: adapt it'
      )
      assert_equal %w[a b], store.batch&.keys&.sort, canary(
        :write_multi_entries, 'write_multi no longer writes through write_multi_entries',
        'RailsCache.multi_write? decides from it whether a store batches its writes'
      )
      assert_equal [false, true, true], [ActiveSupport::Cache::MemoryStore.new, store, redis_store]
        .map { |candidate| PermissionForge::Cache::RailsCache.multi_write?(candidate) }, canary(
          :write_multi_entries, 'the stores that override write_multi_entries changed',
          'RailsCache#write_many trusts one answer for a batch only where the store sends it in one call'
        )
    end

    # What RailsCache#write_multi relies on to tell a written batch from one
    # Redis never got: the store hands the error to the handler it keeps in
    # @error_handler, in the thread that called write_multi, and does not
    # raise. Its answer is not relied on (Rails 8.2's is the same either way).
    canary_test :redis_write_multi_answer,
                'RedisCacheStore#write_multi: a batch Redis did not take is handed to the store\'s @error_handler, not raised' do
      calls = []
      handler = ->(**details) { calls << details }
      store = ActiveSupport::Cache::RedisCacheStore.new(url: 'redis://127.0.0.1:1/15', pool: false, error_handler: handler)

      assert_same handler, store.instance_variable_get(:@error_handler), canary(
        :redis_write_multi_answer, 'the store no longer keeps its error_handler: in @error_handler',
        'Cache::HandledErrors wraps @error_handler to see the errors the store rescues: find where the handler is kept'
      )
      written, handled = PermissionForge::Cache::HandledErrors.during(store) do
        store.write_multi('pf:canary:a' => 1, 'pf:canary:b' => 2)
      end

      assert_not_empty handled, canary(
        :redis_write_multi_answer, "write_multi against a Redis that cannot be reached called no error handler (answered #{written.inspect})",
        'RailsCache#write_multi would take the batch for written (write_many / expunge_many / delete_many): a failed ' \
        'invalidation reported as done, never retried. Find the sign this Rails gives (or write key by key: #write answers)'
      )
      assert_kind_of Exception, handled.first, canary(
        :redis_write_multi_answer, 'the error handler is no longer given the exception:', 'adapt Cache::HandledErrors::Handler'
      )
      assert_equal handled, calls.pluck(:exception), canary(
        :redis_write_multi_answer, 'the handler the store was given was not called with the same error',
        'adapt Cache::HandledErrors::Handler (it must hand every call on unchanged)'
      )
    end

    canary_test :local_cache, 'Cache::Strategy::LocalCache#with_local_cache: a nested local cache starts empty, the outer one is left as it was' do
      store = ActiveSupport::Cache::NullStore.new
      cache = PermissionForge::Cache::RailsCache.new(store: store)
      store.with_local_cache do
        cache.write('user_1', { 'built' => true })

        assert_equal({ built: true }, cache.read('user_1'))
        assert_nil cache.read_fresh('user_1'), canary(
          :local_cache, 'a nested with_local_cache sees the outer local copies',
          'RailsCache#read_fresh / #read_many must read past the request\'s local cache (the stamp check): find another way'
        )
        assert_equal({ built: true }, cache.read('user_1'),
                     canary(:local_cache, 'the nested local cache replaced the outer one', 'adapt RailsCache#read_fresh'))
      end
    end

    canary_test :key_matcher_anchor, 'Cache::Store#key_matcher: a Regexp starting with ^ is anchored right after the store\'s namespace' do
      regexp, = PermissionForge::Cache::UserKeys.entry_patterns('v2', prefix: 'pf')
      [nil, 'host'].each do |namespace|
        store = ActiveSupport::Cache::MemoryStore.new(namespace: namespace)
        %w[pf:v2:user_1 pf:v2:tenant_3_user_1 pf:v2:user_1_invalidation other:pf:v2:user_1].each { |key| store.write(key, 1) }
        store.delete_matched(regexp)
        left = %w[pf:v2:user_1 pf:v2:tenant_3_user_1 pf:v2:user_1_invalidation other:pf:v2:user_1].select { |key| store.exist?(key) }

        assert_equal %w[pf:v2:user_1_invalidation other:pf:v2:user_1], left, canary(
          :key_matcher_anchor, "delete_matched(#{regexp.inspect}) on a store with namespace #{namespace.inspect} left #{left.inspect}",
          'UserKeys.entry_patterns relies on key_matcher keeping a leading ^ when it puts the namespace in front: ' \
          'Cache::Base#clear_entries (its canary keys) would report the clear as failed'
        )
      end
      matcher = ActiveSupport::Cache::MemoryStore.new.send(:key_matcher, /^pf:/, namespace: 'host')
      assert_equal(/^host:pf:/, matcher, canary(
                                           :key_matcher_anchor, "key_matcher(/^pf:/, namespace: 'host') is #{matcher.inspect}",
                                           'UserKeys.entry_patterns relies on the ^ being kept right after the namespace'
                                         ))
    end

    canary_test :redis_store_kind, 'Redis cache store kind: its class name says Redis; memory and file stores take a Regexp in delete_matched' do
      redis = redis_store
      Dir.mktmpdir do |dir|
        regexp_stores = [ActiveSupport::Cache::MemoryStore.new, ActiveSupport::Cache::FileStore.new(dir)]

        assert_includes redis.class.name, 'Redis', canary(
          :redis_store_kind, "the Redis store is called #{redis.class.name}",
          'RailsCache#redis_store? decides glob vs Regexp for delete_matched by the class name: adapt it'
        )
        # The gem sends the Redis store globs, which it takes whether or not
        # it learns Regexps; the memory and file stores must take a Regexp.
        regexp_stores.each { |store| store.delete_matched(/^pf:/) }
        kinds = [redis, *regexp_stores].map { |store| PermissionForge::Cache::RailsCache.new(store: store).send(:redis_store?) }
        assert_equal [true, false, false], kinds, canary(
          :redis_store_kind, "redis_store? answers #{kinds.inspect} for the Redis, memory and file stores",
          'RailsCache#redis_store? decides glob vs Regexp for delete_matched: adapt it'
        )
      end
    end

    # --- scoping and finders ----------------------------------------------------------------------------------

    canary_test :default_scope, 'default_scope { }: evaluated at every relation build, all inside it is unscoped, unscoped skips it' do
      runs = []
      model = canary_model do
        define_singleton_method(:pf_canary_scope) { (runs << :run) && all.where(name: 'scoped') }
        default_scope { pf_canary_scope }
      end
      first = model.all.to_sql
      after_first = runs.size
      model.where(email: 'x').to_sql
      after_second = runs.size
      unscoped = model.unscoped.to_sql

      assert_equal 1, first.scan("'scoped'").size, canary(
        :default_scope, "the default scope was applied #{first.scan("'scoped'").size} times (`all` inside the block re-applied it?)",
        'AutoPermissionScoping#pf_auto_permission_scope starts from all: find the unscoped relation to build on'
      )
      assert_operator after_first, :>=, 1
      assert_operator after_second, :>, after_first, canary(
        :default_scope, 'the block did not run again for a second relation (cached?)',
        'auto-scoping decides per query (current user, config): it must run for every relation'
      )
      assert_not_includes unscoped, 'scoped'
      assert_equal after_second, runs.size, 'unscoped must not run the default scope'
    end

    canary_test :find_by_override, 'find_by / find_by!: a singleton override wins, and the relation\'s find_by never calls the class\'s' do
      calls = []
      model = canary_model do
        # Re-entered: the relation's find_by came back through the class's.
        define_singleton_method(:find_by) do |*args|
          next :reentered if calls.size > 3

          (calls << :class) && where(nil).find_by(*args)
        end
        define_singleton_method(:find_by!) { |*args| (calls << :class!) && (where(nil).find_by(*args) || raise(ActiveRecord::RecordNotFound)) }
      end
      model.create!(name: 'found')
      found = model.find_by(name: 'found')
      not_found = begin
        model.find_by!(name: 'nothing')
      rescue ActiveRecord::RecordNotFound => e
        e
      end

      assert_equal %i[class class!], calls, canary(
        :find_by_override, "calls: #{calls.inspect} — the relation's find_by went through the class's, or the override was skipped",
        'the override finds its record with where(...).take, so it does not recurse; but a host\'s Model.where(...).find_by ' \
        'would now run through the override (row rules under the relation\'s scope): check PermissionScopedFindable and docs/query-scoping.md'
      )
      assert_equal 'found', found&.name, canary(:find_by_override, "the override answered #{found.inspect}", RailsInternalsCanary::FIXES[:find_by_override])
      assert_kind_of ActiveRecord::RecordNotFound, not_found,
                     canary(:find_by_override, "find_by! answered #{not_found.inspect}", RailsInternalsCanary::FIXES[:find_by_override])
    end

    canary_test :counter_updates, 'increment! / decrement!: update through update_counters (class or relation)' do
      seen = []
      model = canary_model do
        define_singleton_method(:update_counters) { |*args, **kwargs| (seen << :class) && super(*args, **kwargs) }
      end
      model.relation_delegate_class(ActiveRecord::Relation).prepend(
        Module.new { define_method(:update_counters) { |*args, **kwargs| (seen << :relation) && super(*args, **kwargs) } }
      )
      record = model.create!(parent_id: 1)
      paths = %i[increment! decrement!].map do |operation|
        seen.clear
        record.public_send(operation, :parent_id)
        seen.dup
      end

      assert paths.all?(&:any?), canary(
        :counter_updates, "increment!/decrement! no longer go through update_counters (paths: #{paths.inspect})",
        'PermissionForge::AuditEvent refuses counter updates in update_counters on the class and its relations ' \
        '(AuditEvent::InsertOnly): an audit row could be incremented. Refuse the new write path in InsertOnly too'
      )
    end

    canary_test :relation_delegate_class, 'relation_delegate_class(ActiveRecord::Relation): the class of every relation of the model' do
      model = canary_model
      delegate = model.relation_delegate_class(ActiveRecord::Relation)
      delegate.prepend(Module.new { def upsert_all(*, **) = :refused })

      assert_equal [delegate, delegate], [model.all.class, model.where(name: 'x').class], canary(
        :relation_delegate_class, 'relations are not instances of relation_delegate_class(ActiveRecord::Relation)',
        'PermissionForge::AuditEvent prepends InsertOnly there to refuse upsert/upsert_all on a relation: find the class now'
      )
      assert_equal :refused, model.where(name: 'x').upsert_all([{ name: 'y' }]),
                   canary(:relation_delegate_class, 'a module prepended to the relation class is not reached', RailsInternalsCanary::FIXES[:relation_delegate_class])
      assert_includes PermissionForge::AuditEvent.where(nil).class.ancestors, PermissionForge::AuditEvent::InsertOnly, canary(
        :relation_delegate_class, 'PermissionForge::AuditEvent relations do not include InsertOnly',
        'upsert/upsert_all on an AuditEvent relation would rewrite audit rows: prepend InsertOnly where relations are built now'
      )
    end

    # --- controllers ------------------------------------------------------------------------------------------

    canary_test :process_action_callbacks,
                '_process_action_callbacks: the before_action chain, each callback with #filter; a limited skip keeps it' do
      guarded = Class.new(ActionController::Base) do
        before_action :pf_canary_guard
        def pf_canary_guard = nil
      end
      limited = Class.new(guarded) { skip_before_action :pf_canary_guard, only: :index }
      skipped = Class.new(guarded) { skip_before_action :pf_canary_guard }

      assert guarded.respond_to?(:_process_action_callbacks), canary(
        :process_action_callbacks, '_process_action_callbacks is gone',
        'ControllerActions.guarded? raises ConfigurationError (admin catalog entries are dropped, SecurityAudit fails) until it reads the new chain'
      )
      listed = [guarded, limited, skipped].map { |klass| klass._process_action_callbacks.any? { |callback| callback.filter == :pf_canary_guard } }

      assert_equal [true, true, false], listed, canary(
        :process_action_callbacks, "the guard callback is listed as #{listed.inspect} (guarded, skip only:, blanket skip)",
        'ControllerActions.guarded? (admin catalog, SecurityAudit action check) reads the chain: adapt it'
      )
    end

    # --- Arel ---------------------------------------------------------------------------------------------------

    canary_test :arel_grouping, 'Arel::Nodes::Grouping: a grouped predicate is not taken for attributes of new records' do
      table = PfCanaryRecord.arel_table
      grouped = PfCanaryRecord.where(Arel::Nodes::Grouping.new(table[:name].eq('rule')))

      message = canary(
        :arel_grouping, 'where_values_hash now sees inside a Grouping',
        'Operators::Registry#grouped keeps rule predicates out of Model.new/create under a default scope: find another wrapper'
      )
      assert_empty grouped.where_values_hash, message
      assert_nil grouped.new.name
      assert_equal 'rule', PfCanaryRecord.where(name: 'rule').new.name
    end

    canary_test :arel_between, 'Arel::Nodes::Between / And / build_quoted, and matches(pattern, escape): the SQL the rule operators build' do
      PfCanaryRecord.create!(name: 'b')
      PfCanaryRecord.create!(name: 'z')
      column = Arel.sql(pool.with_connection { |connection| connection.quote_table_name('pf_canary_records.name') })
      bounds = %w[a m].map { |bound| Arel::Nodes.build_quoted(bound) }
      between = PfCanaryRecord.where(Arel::Nodes::Between.new(column, Arel::Nodes::And.new(bounds)))
      like = PfCanaryRecord.where(column.matches('b%', '\\'))

      assert_equal [%w[b], %w[b]], [between.pluck(:name), like.pluck(:name)], canary(
        :arel_between, 'Between/And/build_quoted or SqlLiteral#matches with an escape no longer build the expected query',
        'Operators::Registry (between, starts_with, ends_with, contains) builds them: adapt the operators and RlsOperatorSql parity'
      )
      message = canary(:arel_matches, 'matches(pattern, escape) dropped the ESCAPE clause',
                       'LIKE patterns would treat % and _ in rule values as wildcards')
      assert_match(/ESCAPE/, like.to_sql, message)
    end

    canary_test :arel_named_function, 'Arel::Nodes::NamedFunction: COALESCE over two columns' do
      table = PfCanaryRecord.arel_table
      PfCanaryRecord.create!(email: 'fallback')
      function = Arel::Nodes::NamedFunction.new('COALESCE', [table[:name], table[:email]])

      assert_equal ['fallback'], PfCanaryRecord.where(function.eq('fallback')).pluck(:email), canary(
        :arel_named_function, 'NamedFunction no longer builds a function call',
        'PermissionSetUser.last_reviewed_column (stale assignment review) builds COALESCE with it'
      )
    end

    # --- schema and loading -----------------------------------------------------------------------------------

    canary_test :schema_cache, 'connection.schema_cache.columns_hash(table): Columns by name, with name and type' do
      columns = pool.with_connection { |connection| connection.schema_cache.columns_hash('pf_canary_records') }

      assert_equal %w[email id name parent_id prefs], columns.keys.sort, canary(
        :schema_cache, 'schema_cache.columns_hash no longer answers the columns of a table by name',
        'Operators::RuleColumn.on types every rule value from it: adapt it'
      )
      assert_equal [:string, 'email'], [columns['email'].type, columns['email'].name],
                   canary(:schema_cache, 'a Column no longer answers name / type',
                          'Operators::ValueCasters pick a caster by column type: adapt RuleColumn')
    end

    canary_test :association_join_checks,
                '_reflect_on_association / check_validity! / check_eager_loadable! / polymorphic? / klass: what joins checks' do
      model = canary_model('PfCanaryJoinModel') do
        belongs_to :parent, class_name: 'PfCanaryRecord', optional: true
        belongs_to :subject, polymorphic: true, optional: true
        belongs_to :phantom, class_name: 'PfCanaryNoSuchModel', optional: true
        has_many :namesakes, ->(record) { where(name: record.name) }, class_name: 'PfCanaryRecord', foreign_key: :parent_id
        has_many :ghosts, through: :nowhere, source: :children
      end
      joins = lambda do |name|
        model.joins(name).to_sql
        true
      rescue StandardError
        false
      end

      assert_nil model._reflect_on_association('nowhere')
      assert_not joins.call(:nowhere)

      parent = model._reflect_on_association('parent')
      parent.check_validity!
      parent.check_eager_loadable!

      assert_not parent.polymorphic?
      assert_equal [PfCanaryRecord, true], [parent.klass, joins.call(:parent)], canary(
        :association_join_checks, 'an association joins builds was not found, or a check refused it',
        RailsInternalsCanary::FIXES[:association_join_checks]
      )
      assert model._reflect_on_association('subject').polymorphic?
      assert_raises(ArgumentError) { model._reflect_on_association('namesakes').check_eager_loadable! }
      assert_raises(ActiveRecord::ActiveRecordError) { model._reflect_on_association('ghosts').check_validity! }
      assert_raises(NameError) { model._reflect_on_association('phantom').klass }
      assert_equal [false] * 4, %i[subject namesakes ghosts phantom].map { |name| joins.call(name) }, canary(
        :association_join_checks, 'joins now builds a join RulePath counts as broken (it matches nothing)',
        RailsInternalsCanary::FIXES[:association_join_checks]
      )
    end

    canary_test :preloader, 'Associations::Preloader.new(records:, associations:).call: loads the association of the records given' do
      parent = PfCanaryRecord.create!(name: 'parent')
      child = PfCanaryRecord.find(PfCanaryRecord.create!(name: 'child', parent: parent).id)
      ActiveRecord::Associations::Preloader.new(records: [child], associations: [:parent]).call

      assert child.association(:parent).loaded?, canary(
        :preloader, 'Preloader.new(records:, associations:).call did not load the association',
        'PermissionHashBuilder#preload loads the grantors of assignments with it: adapt it'
      )
      assert_equal parent, child.parent
    end

    canary_test :association_target, 'Association#target: the loaded records themselves, sorted in place; loaded? and the built target' do
      parent = PfCanaryRecord.create!(name: 'parent')
      ids = Array.new(3) { |i| PfCanaryRecord.create!(name: "child #{i}", parent: parent).id }
      loaded = PfCanaryRecord.includes(:children).find(parent.id)
      association = loaded.association(:children)
      association.target.sort_by! { |row| -row.id }
      descending = loaded.children.map(&:id)
      PermissionForge::Services::PermissionHashBuilder.send(:sorted, association)

      assert association.loaded?, canary(:association_target, 'a preloaded has_many is not loaded?', RailsInternalsCanary::FIXES[:association_target])
      assert_equal [ids.reverse, ids], [descending, loaded.children.map(&:id)], canary(
        :association_target, 'sorting association.target in place does not change the order the association yields',
        'PermissionHashBuilder.sorted (sort_rows) puts resource rows in id order in place: the first row of a name wins a ' \
        'variant tie ("first mask_strategy wins"), and rules and actions keep that order. Sort what the association yields now'
      )
      built = PfCanaryRecord.new(parent: parent).association(:parent)
      answers = [built.loaded?, built.target.equal?(parent), built.reflection.foreign_key.to_s, built.klass]
      assert_equal [true, true, 'parent_id', PfCanaryRecord], answers,
                   canary(:association_target, 'a built belongs_to does not answer loaded?/target/reflection/klass as before', RailsInternalsCanary::FIXES[:association_target])
    end

    canary_test :journey_route, 'Journey routes: verb, path.spec, defaults and internal, as Admin::ControllerCatalog reads them' do
      routes = ActionDispatch::Routing::RouteSet.new
      routes.draw do
        get 'pf_canary/:id', to: 'pf_canary#show'
        match 'pf_canary/any', to: 'pf_canary#any', via: :all
        match 'pf_canary/two', to: 'pf_canary#two', via: %i[get post]
        get 'pf_canary/internal', to: 'pf_canary#internal', internal: true
        get 'pf_canary/old', to: redirect('/pf_canary/1')
      end
      routed = PermissionForge::Admin::ControllerCatalog.const_get(:RoutedAction)
      read = routes.routes.map { |route| routed.new(route) }.map { |action| [action.target, action.verbs, action.path] }

      assert_equal [[%w[pf_canary show], ['GET'], '/pf_canary/:id'],
                    [%w[pf_canary any], [PermissionForge::Admin::ControllerCatalog::ANY_VERB], '/pf_canary/any'],
                    [%w[pf_canary two], %w[GET POST], '/pf_canary/two'],
                    [nil, ['GET'], '/pf_canary/internal'], [nil, ['GET'], '/pf_canary/old']], read, canary(
                      :journey_route, "the catalog reads the routes as #{read.inspect}",
                      'Admin::ControllerCatalog::RoutedAction reads Journey::Route#verb ("GET|POST"), #path.spec ' \
                      '("…(.:format)"), #defaults and #internal (all :nodoc:): adapt it, or the admin lists no (or wrong) host actions'
                    )
    end

    # In a child process: loading the generate command here would make every
    # later boot check in this process look like a generator's.
    canary_test :generator_commands,
                '`bin/rails generate` / `destroy` load Rails::Command::GenerateCommand / DestroyCommand (:nodoc:); ' \
                'server, console and runner do not' do
      script = <<~RUBY
        require 'json'
        require 'rails/command'
        %w[server console runner].each { |name| Rails::Command.find_by_namespace(name) }
        others = %w[GenerateCommand DestroyCommand].select { |name| Rails::Command.const_defined?(name, false) }
        generators = %w[generate destroy].map { |name| Rails::Command.find_by_namespace(name)&.name }
        puts JSON.generate('others' => others, 'generators' => generators)
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, '-e', script)
      assert status.success?, output
      result = JSON.parse(output.lines.reverse.find { |line| line.start_with?('{') })

      assert_equal [], result['others'], 'a server, a console or a runner loads no generator command'
      assert_equal %w[Rails::Command::GenerateCommand Rails::Command::DestroyCommand], result['generators']
      assert_equal PermissionForge::BootChecks::GENERATOR_COMMANDS, result['generators']
    end

    canary_test :sandbox, 'Rails.application.sandbox?: false outside `rails console --sandbox`' do
      assert Rails.application.respond_to?(:sandbox?), canary(
        :sandbox, 'Rails.application.sandbox? is gone',
        'OpenTransaction.sandbox? then never sees a sandbox console, whose hashes would be cached although nothing is committed'
      )
      assert_includes [nil, false], Rails.application.sandbox?
    end
  end
end
