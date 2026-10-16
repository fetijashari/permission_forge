# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/boot_test_helpers'
require_relative '../cache/failing_store'

module PermissionForge
  module ReleaseReadiness
    # Pre-release review: auto-applied masking across processes (MaskingSync).
    # Integrity lane INT-N1 and INT-N2, performance lane NEW-MINOR-1
    # (PERF-N1b). "Another process" is this one with a model class it has not
    # masked yet, as in masking_sync_test.rb.
    class MaskingSyncRegressionTest < ActiveSupport::TestCase
      include PermissionForge::BootTestHelpers

      KEY = PermissionForge::MaskingSync::KEY

      setup do
        @model = fresh_model
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
        PermissionForge::MaskingSync.reset!
        PermissionForge::MaskingSync.boot!
      end

      def use_store(store)
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!
        store
      end

      def fresh_model
        name = :"PfRrSyncProbe#{SecureRandom.hex(4)}"
        Object.const_set(name, Class.new(ActiveRecord::Base) { self.table_name = 'customers' })
      end

      def applied?(klass)
        PermissionForge::Concerns::MaskedAttributes.applied?(klass)
      end

      # What another process does: commits a row naming the model (without
      # masking it here) and writes a token with the store's own options.
      def named_elsewhere(klass)
        PermissionForge.configuration.auto_apply_masked_attributes = false
        create_resource(permission_set: create_permission_set(name: "Set for #{klass.name}"), name: klass.name)
        PermissionForge.configuration.auto_apply_masked_attributes = :auto
        PermissionForge.cache.write(KEY, SecureRandom.uuid)
      end

      # ---- INT-N1: a lost token hid a newly named model from a process that synced with none ----

      # A host Rails.cache with a global expires_in (or an LRU store) lost
      # the token while a process was idle: a process that had synced with
      # no token read nil again, saw no change and kept serving the model
      # unmasked until its restart.
      test 'INT-N1 a model named while this process was idle is masked here after the token expired' do
        use_store(ActiveSupport::Cache::MemoryStore.new(expires_in: 1))
        PermissionForge::MaskingSync.reset!
        PermissionForge::MaskingSync.boot!

        travel 2.seconds
        assert PermissionForge.cache.read(KEY), 'the token is written with no expiry, whatever the store default'

        named_elsewhere(@model)
        travel 2.seconds
        assert_nil PermissionForge.cache.read(KEY), 'precondition: the token of the other process expired'

        PermissionForge::MaskingSync.check!

        assert applied?(@model)
        assert PermissionForge.cache.read(KEY), 'the store is not left without a token'
      end

      test 'INT-N1 an evicted token reads as a change in every process, which syncs once' do
        PermissionForge::MaskingSync.boot!
        named_elsewhere(@model)
        PermissionForge.cache.delete(KEY) # evicted

        PermissionForge::MaskingSync.check!
        assert applied?(@model)
        token = PermissionForge.cache.read(KEY)

        PermissionForge::MaskingSync.check!
        assert_equal token, PermissionForge.cache.read(KEY), 'no new token once one is there'
      end

      # ---- INT-N2: two rows for one new model committed together announced nothing ----

      test 'INT-N2 two rows for a new model committed in one transaction tell the other processes' do
        before = PermissionForge.cache.read(KEY)

        ActiveRecord::Base.transaction do
          create_resource(permission_set: create_permission_set(name: 'Sales'), name: @model.name)
          create_resource(permission_set: create_permission_set(name: 'Support'), name: @model.name)
        end

        assert applied?(@model)
        token = PermissionForge.cache.read(KEY)
        refute_equal before, token, 'the other processes were not told'

        create_resource(permission_set: create_permission_set(name: 'Third'), name: @model.name)
        assert_equal token, PermissionForge.cache.read(KEY), 'a later row for a model masked here announces nothing'
      end

      # ---- Final-round verification N7 / N8: an announcement made while the store is down ----

      def pause_over!
        PermissionForge::MaskingSync.instance_variable_set(:@failing_until, 0.0)
      end

      # N7: the admin's process committed the first row for a model while the
      # store was down; the token write failed and the store came back with
      # the old token, so no other process ever masked the model (only the
      # next newly named model, or a restart, did).
      test 'INT-N7 an announcement the store did not take is written once the store answers again' do
        store = use_store(PermissionForge::Cache::FailingStore.new)
        PermissionForge::MaskingSync.boot!
        before = PermissionForge.cache.read(KEY)
        store.down!

        log = capture_rails_log { create_resource(permission_set: create_permission_set(name: 'Outage'), name: @model.name) }
        assert applied?(@model), 'masked here'
        assert_match(/did not take the masking token/, log)

        store.up!
        PermissionForge::MaskingSync.check!
        assert_equal before, PermissionForge.cache.read(KEY), 'not within the pause'

        pause_over!
        PermissionForge::MaskingSync.check!
        token = PermissionForge.cache.read(KEY)
        refute_equal before, token, 'the other processes are told once the store answers'

        PermissionForge::MaskingSync.check!
        assert_equal token, PermissionForge.cache.read(KEY), 'written once'
      end

      # N8: a store without a failsafe raised out of the Resource's
      # after_commit (the row committed, the caller got an error).
      test 'INT-N8 a store that raises on the announcement never breaks the Resource save, and the announcement is owed' do
        store = use_store(PermissionForge::Cache::FailingStore.new)
        PermissionForge::MaskingSync.boot!
        before = PermissionForge.cache.read(KEY)
        store.raise_instead = true
        store.down!

        log = capture_rails_log do
          assert_nothing_raised { create_resource(permission_set: create_permission_set(name: 'Raising'), name: @model.name) }
        end
        assert PermissionForge::Resource.unscoped.exists?(name: @model.name)
        assert applied?(@model)
        assert_match(/the cache server is gone/, log)

        store.up!
        pause_over!
        PermissionForge::MaskingSync.check!
        refute_equal before, PermissionForge.cache.read(KEY)
      end

      # ---- PERF-N1b: a store that does not answer was read at every request or job ----

      test 'PERF-N1b a store that does not answer is asked once per pause and logged once' do
        store = use_store(PermissionForge::Cache::FailingStore.new)
        PermissionForge::MaskingSync.boot!
        store.down!
        store.operations.clear

        log = capture_rails_log { 5.times { Rails.application.executor.wrap { nil } } }

        assert_equal [[:read, KEY], [:write, KEY]], store.operations, 'one read and one write for five runs'
        assert_equal 1, log.scan('did not give or keep the masking token').size, log
        # Field test (R2 #92): the line named no cause. A store that raised nothing answered nothing.
        cause = 'it did not answer, or a read right after a write came back empty: the store is down, full, or evicts the key at once'
        assert_match(/masking token \(#{Regexp.escape(cause)}\): auto-applied masking/, log)
        assert_match(/use a shared store that keeps entries, or include PermissionForge::Concerns::MaskedAttributes/, log, 'the remedy')
        assert_predicate PermissionForge::MaskingSync, :store_failing?
        use_store(ActiveSupport::Cache::MemoryStore.new)
        assert_not_predicate PermissionForge::MaskingSync, :store_failing?, 'a store that replaced it has not failed'
        PermissionForge.configuration.cache_backend = store
        PermissionForge.configuration.reset_cache_store!

        store.up!
        PermissionForge::MaskingSync.instance_variable_set(:@failing_until, 0.0) # the pause is over
        log = capture_rails_log { PermissionForge::MaskingSync.check! }
        assert_not_predicate PermissionForge::MaskingSync, :store_failing?
        assert_empty log
      end

      test 'PERF-N1b a store that raises is left alone too, and a process that never synced still applies' do
        store = use_store(PermissionForge::Cache::FailingStore.new)
        store.raise_instead = true
        store.down!
        named_elsewhere(@model) rescue nil # rubocop:disable Style/RescueModifier -- the store raises on the token write
        PermissionForge::MaskingSync.reset!
        store.operations.clear

        PermissionForge::MaskingSync.check!
        PermissionForge::MaskingSync.check!

        assert applied?(@model), 'applied from the database'
        assert_equal(1, store.operations.count { |operation, _key| operation == :read })
        assert_equal([[:read, KEY]], store.operations.select { |_operation, key| key == KEY }, 'no token write after a read that raised')
      end

      # Final-round verification (performance): when the pause ended, every
      # request that arrived while the store was being probed probed it too
      # (8 threads: 8 x two timeouts). One probes; the others keep the pause.
      test 'PERF-N1b when the pause ends one request probes the store and the others keep the pause' do
        store = use_store(PermissionForge::Cache::FailingStore.new)
        PermissionForge::MaskingSync.boot!
        store.down!
        PermissionForge::MaskingSync.check!
        assert_predicate PermissionForge::MaskingSync, :store_failing?
        # A store that answers only once every other request has come and gone
        # (at most 5 s): each of them arrives while the store is being probed.
        lock = Mutex.new
        returned = ConditionVariable.new
        others_done = 0
        store.define_singleton_method(:read) do |name, options = nil|
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          lock.synchronize do
            while others_done < 7 && (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
              returned.wait(lock, left)
            end
          end
          super(name, options)
        end
        store.operations.clear
        PermissionForge::MaskingSync.instance_variable_set(:@failing_until, 0.0) # the pause is over

        Array.new(8) do
          Thread.new do
            PermissionForge::MaskingSync.check!
            lock.synchronize do
              others_done += 1
              returned.broadcast
            end
          end
        end.each(&:join)

        assert_equal(1, store.operations.count { |operation, key| operation == :read && key == KEY }, store.operations.inspect)
        assert_predicate PermissionForge::MaskingSync, :store_failing?, 'the probe failed: a new pause'
      end
    end
  end
end
