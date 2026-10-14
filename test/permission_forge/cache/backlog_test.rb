# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Cache
    # The list of invalidations a process still owes the store.
    class BacklogTest < ActiveSupport::TestCase
      setup do
        @now = 100.0
        @backlog = Backlog.new(clock: -> { @now })
      end

      test 'a new backlog is empty and owes nobody' do
        assert_empty @backlog
        assert_not listed?(1)
      end

      test 'an entry is listed until a try confirms it' do
        owe(1)
        assert_not_empty @backlog
        assert listed?(1)

        tried = []
        @backlog.try_again { |entry| tried << entry }

        assert_equal [{ user_id: 1, stamp_key: 'user_1_invalidation', keys: ['user_1'] }], tried
        assert_empty @backlog
      end

      test 'a second failure of a user adds its keys and says whether that is news' do
        assert owe(1, keys: ['user_1'])
        assert_not owe(1, keys: ['user_1']), 'exactly this was owed already'
        assert owe(1, keys: %w[tenant_7_user_1 user_1])

        tried = []
        @backlog.try_again { |entry| tried << entry[:keys].sort }

        assert_equal [%w[tenant_7_user_1 user_1]], tried
      end

      test 'a try that fails keeps the entry and moves it behind the others' do
        [1, 2, 3].each { |user_id| owe(user_id) }

        @backlog.try_again { |entry| entry[:user_id] != 1 }

        assert listed?(1)
        assert_not listed?(2)
        assert_not listed?(3)

        owe(4)
        @now += Backlog::PAUSE
        order = []
        @backlog.try_again { |entry| order << entry[:user_id] }

        assert_equal [1, 4], order
      end

      test 'a pass stops after three failed tries and the next one starts with the entries it did not reach' do
        (1..6).each { |user_id| owe(user_id) }
        tried = []

        @backlog.try_again do |entry|
          tried << entry[:user_id]
          false
        end
        assert_equal [1, 2, 3], tried

        @now += Backlog::PAUSE
        @backlog.try_again do |entry|
          tried << entry[:user_id]
          false
        end
        assert_equal [1, 2, 3, 4, 5, 6], tried
      end

      test 'a pass makes a limited number of tries and the next one goes on with the rest, without waiting' do
        owed = (Backlog::PER_PASS * 2) + 3
        (1..owed).each { |user_id| owe(user_id) }
        passes = Array.new(3) do
          tried = []
          @backlog.try_again { |entry| tried << entry[:user_id] }
          tried
        end

        assert_equal [Backlog::PER_PASS, Backlog::PER_PASS, 3], passes.map(&:size)
        assert_equal (1..owed).to_a, passes.flatten
        assert_empty @backlog
      end

      test 'after a pass that failed the next one waits' do
        owe(1)
        passes = 0
        failing = lambda do |_entry|
          passes += 1
          false
        end

        @backlog.try_again(&failing)
        @backlog.try_again(&failing)
        @now += Backlog::PAUSE - 0.1
        @backlog.try_again(&failing)
        assert_equal 1, passes

        @now += 0.1
        @backlog.try_again(&failing)
        assert_equal 2, passes
      end

      test 'a pass in which every try was confirmed is not followed by a wait' do
        owe(1)
        @backlog.try_again { true }
        owe(2)
        tried = []

        @backlog.try_again { |entry| tried << entry[:user_id] }

        assert_equal [2], tried
      end

      test 'a failure that arrives while its user is being tried is not lost with the old entry' do
        owe(1, keys: ['user_1'])

        @backlog.try_again do |_entry|
          owe(1, keys: ['tenant_7_user_1'])
          true
        end

        assert listed?(1), 'the new failure names a key the try did not remove'
      end

      test 'only one pass runs at a time' do
        owe(1)
        nested = 0

        @backlog.try_again do |_entry|
          @backlog.try_again { nested += 1 }
          true
        end

        assert_equal 0, nested
      end

      test 'a pass that raises lets the next one run' do
        owe(1)

        assert_raises(RuntimeError) { @backlog.try_again { raise 'broken' } }
        tried = 0
        @backlog.try_again { tried += 1 }

        assert_equal 1, tried
      end

      test 'the list is bounded: the user owed longest makes room' do
        (1..(Backlog::LIMIT + 2)).each { |user_id| owe(user_id) }

        assert_not listed?(1)
        assert_not listed?(2)
        assert listed?(3)
        assert listed?(Backlog::LIMIT + 2)
      end

      # The managed-actions index is owed under its own stamp key, by nobody.
      test 'an entry that belongs to no user is listed by its stamp key, apart from the users' do
        owe(1)
        assert @backlog.add(user_id: nil, stamp_key: 'managed_actions_invalidation', keys: ['managed_actions'])

        assert @backlog.include?('managed_actions_invalidation')
        tried = []
        @backlog.try_again { |entry| tried << entry[:stamp_key] }
        assert_equal %w[user_1_invalidation managed_actions_invalidation], tried
      end

      test 'clear forgets the entries and the wait' do
        owe(1)
        @backlog.try_again { false }

        @backlog.clear
        assert_empty @backlog

        owe(2)
        tried = 0
        @backlog.try_again { tried += 1 }
        assert_equal 1, tried
      end

      private

      # An entry is listed by its stamp key.
      def listed?(user_id)
        @backlog.include?("user_#{user_id}_invalidation")
      end

      def owe(user_id, keys: ["user_#{user_id}"])
        @backlog.add(user_id: user_id, stamp_key: "user_#{user_id}_invalidation", keys: keys)
      end
    end
  end
end
