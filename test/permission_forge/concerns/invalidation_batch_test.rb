# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  # The batch on its own. A connection only has to answer open_transactions,
  # so a stand-in lets every transaction depth be set directly.
  class InvalidationBatchTest < ActiveSupport::TestCase
    include PermissionForge::Tenancy::TenancyTestHelper

    Connection = Struct.new(:open_transactions)

    setup do
      ExecutionState[InvalidationBatch::THREAD_KEY] = nil
      @connection = Connection.new(0)
    end

    # --- joining -------------------------------------------------------------

    test 'records written on one connection join the same open batch' do
      batch = InvalidationBatch.join(@connection)

      assert_same batch, InvalidationBatch.join(@connection)
    end

    test 'another connection gets its own batch' do
      batch = InvalidationBatch.join(@connection)

      assert_not_same batch, InvalidationBatch.join(Connection.new(0))
    end

    test 'a claimed batch is never handed out again' do
      batch = InvalidationBatch.join(@connection)
      batch.claim

      assert_not batch.open_on?(@connection)
      assert_nil ExecutionState[InvalidationBatch::THREAD_KEY], 'the thread keeps nothing of it'
      assert_not_same batch, InvalidationBatch.join(@connection)
    end

    test 'a batch claimed from another thread is not handed out here either' do
      batch = InvalidationBatch.join(@connection)
      Thread.new { batch.claim }.join

      assert_same batch, ExecutionState[InvalidationBatch::THREAD_KEY], 'still the one this thread last opened'
      assert_not_same batch, InvalidationBatch.join(@connection)
    end

    test 'an open batch survives a rollback: nothing claimed it, so it holds nothing' do
      batch = InvalidationBatch.join(@connection)
      @connection.open_transactions = 1
      @connection.open_transactions = 0

      assert_same batch, InvalidationBatch.join(@connection)
      assert batch.claim
    end

    test 'each thread has its own open batch' do
      batch = InvalidationBatch.join(@connection)
      other = Thread.new { InvalidationBatch.join(@connection) }.value

      assert_not_same batch, other
      assert_same batch, InvalidationBatch.join(@connection)
    end

    # --- claiming ------------------------------------------------------------

    test 'every record of the commit that claimed the batch may use it' do
      batch = InvalidationBatch.join(@connection)

      assert batch.claim
      assert batch.claim
    end

    test 'a commit at another transaction depth may not use it' do
      batch = InvalidationBatch.join(@connection)
      @connection.open_transactions = 2
      assert batch.claim, 'claimed by a transaction nested in a non-joinable one'

      @connection.open_transactions = 0
      assert_not batch.claim, 'the outer transaction committed later'

      @connection.open_transactions = 2
      assert batch.claim
    end

    test 'a commit under another tenant may not use it' do
      batch = InvalidationBatch.join(@connection)
      assert batch.claim

      within(Account.create!(name: 'Other')) { assert_not batch.claim }
      assert batch.claim
    end

    test 'a batch nothing was written through cannot be claimed' do
      assert_not InvalidationBatch.new.claim
    end

    # --- what it remembers -----------------------------------------------------

    test 'fetch runs a lookup once, whatever it returns' do
      batch = InvalidationBatch.new
      runs = 0

      [:found, nil, false].each do |value|
        2.times { assert_equal_or_nil value, batch.fetch([:lookup, value]) { (runs += 1) && value } }
      end

      assert_equal 3, runs
    end

    test 'once runs an invalidation once per key' do
      batch = InvalidationBatch.new
      runs = []

      batch.once([:user, 1, nil]) { runs << :first }
      batch.once([:user, 1, nil]) { runs << :again }
      batch.once([:user, 1, 7]) { runs << :other_tenant }

      assert_equal %i[first other_tenant], runs
    end

    test 'an invalidation that raised is not remembered as done' do
      batch = InvalidationBatch.new
      runs = 0

      assert_raises(RuntimeError) { batch.once(:key) { raise 'cache is down' } }
      batch.once(:key) { runs += 1 }

      assert_equal 1, runs
    end

    # --- a permission record written since ---------------------------------------

    test 'a write on this thread makes the batch forget what it remembers' do
      batch = InvalidationBatch.join(@connection)
      batch.claim
      runs = 0
      batch.once(:key) { runs += 1 }
      batch.fetch(:lookup) { runs += 1 }

      InvalidationBatch.note_write
      assert_same batch, batch.claim, 'still the batch of this commit'
      batch.once(:key) { runs += 1 }
      batch.fetch(:lookup) { runs += 1 }

      assert_equal 4, runs
    end

    test 'joining counts as a write, claiming again without one keeps the memory' do
      batch = InvalidationBatch.join(@connection)
      batch.claim
      runs = 0
      batch.once(:key) { runs += 1 }

      batch.claim
      batch.once(:key) { runs += 1 }
      assert_equal 1, runs

      InvalidationBatch.join(Connection.new(0))
      batch.claim
      batch.once(:key) { runs += 1 }
      assert_equal 2, runs
    end

    # A callback between two after_commits may do its write in another
    # thread or fiber: the count is kept for the process.
    test 'a write on another thread or fiber makes the batch forget as well' do
      batch = InvalidationBatch.join(@connection)
      batch.claim
      runs = 0
      batch.once(:key) { runs += 1 }

      Thread.new { InvalidationBatch.note_write }.join
      batch.claim
      batch.once(:key) { runs += 1 }
      assert_equal 2, runs

      Fiber.new { InvalidationBatch.note_write }.resume
      batch.claim
      batch.once(:key) { runs += 1 }
      assert_equal 3, runs
    end

    test 'concurrent writes are all counted' do
      before = InvalidationBatch.writes

      Array.new(8) { Thread.new { 250.times { InvalidationBatch.note_write } } }.each(&:join)

      assert_equal before + 2000, InvalidationBatch.writes
    end

    # --- notes --------------------------------------------------------------------

    test 'notes are kept per cache, without duplicates, and survive a write' do
      batch = InvalidationBatch.join(@connection)
      batch.note(:managed_actions, 7)
      batch.note(:managed_actions, 7)
      batch.note(:managed_actions, nil)
      batch.claim

      InvalidationBatch.note_write
      batch.claim

      assert_equal [7, nil], batch.noted(:managed_actions)
      assert_equal [], batch.noted(:something_else)
    end

    # --- records are cached and copied ---------------------------------------

    test 'a marshalled batch comes back empty and unusable' do
      batch = InvalidationBatch.join(ActiveRecord::Base.connection_pool.with_connection { |c| c })
      batch.once(:key) { nil }

      batch.note(:managed_actions, 1)

      copy = Marshal.load(Marshal.dump(batch))

      assert_not copy.claim
      assert_equal [], copy.noted(:managed_actions)
      assert_not copy.open_on?(@connection)
      ran = false
      copy.once(:key) { ran = true }
      assert ran
    end

    private

    def assert_equal_or_nil(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
  end
end
