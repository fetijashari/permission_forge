# frozen_string_literal: true

require 'test_helper'
require_relative 'failing_store'

module PermissionForge
  module Cache
    # An invalidation that failed for good while the store was unreachable is
    # still owed (Cache::Backlog). Until the store has confirmed it, this
    # process does not serve that user from the store, and it makes the
    # invalidation as soon as the store answers again.
    class OwedInvalidationTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set
        @users = Array.new(3) { |i| create_user(name: "Person #{i}") }
        @assignments = @users.map { |user| create_permission_set_user(user: user, permission_set: @set) }
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @name = create_resource_field(resource: @resource, name: 'name')
        @bystander = create_user(name: 'Bystander')

        @store = FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
        @reported = []
        PermissionForge.configuration.on_cache_failure = ->(**failure) { @reported << failure }
        @users.each { |user| reader(user).permissions_hash }
        @store.operations.clear
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # --- the reviewer's F02 ---------------------------------------------------------

      test 'a revocation made while the store is down is not a cache hit again when the store is back' do
        revoked = @users.first
        @store.down!
        @assignments.first.destroy!
        assert_equal [[:invalidate, revoked.id]], reported
        assert Invalidation.backlog.include?(stamp_key_of(revoked))

        assert_not reader(revoked).can_read?(:Customer), 'while the store is down'

        @store.up!
        assert cached?(revoked), 'the entry that could not be removed is back in reach'

        assert_not reader(revoked).can_read?(:Customer), 'within the window in which nothing is tried again'
        assert_not stale?(revoked), 'the rebuild replaced the entry'
      end

      test 'while it is owed the user is never read from the store, and the store is not tried inside the window' do
        revoked = @users.first
        @store.down!
        @assignments.first.destroy!
        @store.operations.clear

        reader(revoked).permissions_hash

        assert Invalidation.store_failing?
        assert_not_includes @store.operations, [:read, key_of(revoked)]
        assert_not_includes @store.operations, [:delete, key_of(revoked)]
        assert_equal 1, @store.operations.count([:write, stamp_key_of(revoked)]), 'the rebuild asks for a stamp once; no retry'
      end

      test 'somebody who is not owed is read from the store as always' do
        @store.down!
        @assignments.first.destroy!
        @store.up!
        @store.operations.clear

        reader(@users.last).permissions_hash

        assert_equal [[:read, key_of(@users.last)]], @store.operations
      end

      # --- when it is made ---------------------------------------------------------------

      test 'the next invalidation the store confirms makes the owed ones' do
        @store.down!
        @name.update!(edit_access: true)
        assert_equal @users.map(&:id).sort, reported.map(&:last).sort
        @store.up!
        assert(@users.all? { |user| stale?(user) })
        @reported.clear

        assert reader(@bystander).invalidate_permissions

        assert(@users.none? { |user| cached?(user) })
        assert_empty Invalidation.backlog
        assert_empty @reported, 'making what was owed is nothing to report'
        @users.each { |user| assert reader(user).field_permissions(:Customer, :name)[:edit_access] }
      end

      test 'the next permission read makes the owed ones once the window has passed' do
        @store.down!
        @name.update!(edit_access: true)
        @store.up!

        reader(@bystander).permissions_hash
        assert(@users.all? { |user| stale?(user) }, 'inside the window nothing is tried')

        Invalidation.store_answered! # the window has passed
        reader(@bystander).permissions_hash

        assert(@users.none? { |user| cached?(user) })
        assert_empty Invalidation.backlog
      end

      # A store that shares the database connection (Solid Cache in the
      # application's database) would take the removals back on a rollback.
      test 'what is owed is not made from inside an open transaction, where the owed user is still not read from the store' do
        PermissionForge.configuration.snapshot_transactions = true
        @store.down!
        @name.update!(edit_access: true)
        @store.up!
        Invalidation.store_answered!
        @store.operations.clear

        ActiveRecord::Base.transaction do
          reader(@bystander).permissions_hash
          assert reader(@users.first).field_permissions(:Customer, :name)[:edit_access]
        end

        assert_equal [[:read, key_of(@bystander)]], @store.operations
        assert(@users.all? { |user| Invalidation.backlog.include?(stamp_key_of(user)) })
      end

      test 'a memoized hash asks for nothing' do
        person = reader(@bystander)
        person.permissions_hash
        @store.down!
        @name.update!(edit_access: true)
        Invalidation.store_answered!
        person.permissions_hash # version bumped by the invalidations: read again, pass made
        @store.operations.clear

        3.times { person.permissions_hash }

        assert_empty @store.operations
      end

      test 'an outage adds at most three failing calls to one request, then none for a while' do
        @store.down!
        @name.update!(edit_access: true)
        owed = @users.map { |user| [:write, stamp_key_of(user)] }
        Invalidation.store_answered! # the window has passed, the store is still down
        @store.operations.clear

        reader(@bystander).permissions_hash
        assert_equal owed.sort, (@store.operations & owed).sort, 'one try each, a stamp write and nothing else'
        assert_not_includes @store.operations.map(&:first), :delete

        @store.operations.clear
        reader(@bystander).permissions_hash

        assert_empty @store.operations & owed, 'the pass that failed is followed by a pause'
        assert(@users.all? { |user| Invalidation.backlog.include?(stamp_key_of(user)) })
      end

      test 'what is owed was reported when it failed: a try that fails again reports nothing' do
        @store.down!
        @name.update!(edit_access: true)
        @reported.clear
        Invalidation.store_answered!

        reader(@bystander).permissions_hash

        assert_empty @reported
      end

      # --- the reviewer's F12b: a hiccup inside the single-attempt window --------------------

      test 'a user left stale by one lost call inside the window is made up for by the next confirmed invalidation' do
        dead, hiccup, fine = @users
        lost = 0
        @store.fail_when = lambda do |operation, key|
          next true if key.include?("user_#{dead.id}") # these keys live on a shard that is gone
          next false unless key == key_of(hiccup) && %i[delete write].include?(operation)

          (lost += 1) <= 2 # one delete and the write that follows it are lost
        end

        reader(dead).invalidate_permissions
        assert Invalidation.store_failing?
        lost = 0

        @name.update!(edit_access: true) # hiccup gets a single attempt, which fails; fine's is confirmed

        assert_equal [dead.id, dead.id, hiccup.id], reported.map(&:last)
        assert_not cached?(hiccup), 'tried again right after the invalidation of the third user'
        assert_not cached?(fine)
        assert Invalidation.backlog.include?(stamp_key_of(dead)), 'still owed: its keys keep failing'
        assert_not Invalidation.backlog.include?(stamp_key_of(hiccup))
      end

      # --- the reviewer's F08: a write that was applied and never confirmed -------------------

      test 'a hash the store applied without confirming, and then could not remove, is reported and owed' do
        person = @users.first
        key = key_of(person)
        @store.delete("pf:#{key}")
        broken = false
        @store.fail_when = ->(_operation, name) { broken && name == key }
        builder = PermissionForge::Services::PermissionHashBuilder
        original = builder.method(:call)
        replace_singleton_method(builder, :call) do |**options|
          original.call(**options).tap { broken = true } # from here on the connection for this key is gone
        end
        @store.apply_next_failed_write = true
        @store.operations.clear

        hash = reader(person).permissions_hash

        assert hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        assert_equal [[:discard, person.id]], reported
        assert_equal [key], @reported.first[:keys]
        assert Invalidation.backlog.include?(stamp_key_of(person))

        replace_singleton_method(builder, :call, original)
        @store.up!
        assert cached?(person), 'the entry nobody verified is in the store'

        Invalidation.store_answered!
        reader(@bystander).permissions_hash

        assert_not cached?(person)
        assert_empty Invalidation.backlog
      ensure
        replace_singleton_method(builder, :call, original)
      end

      # --- bounds --------------------------------------------------------------------------------

      test 'a store that is replaced is owed nothing' do
        @store.down!
        @name.update!(edit_access: true)
        assert_not_empty Invalidation.backlog

        PermissionForge.configuration.reset_cache_store!

        assert_empty Invalidation.backlog
        assert_not Invalidation.store_failing?
      end

      private

      def reader(user)
        User.find(user.id)
      end

      def key_of(user)
        user.permission_cache_key
      end

      def stamp_key_of(user)
        "user_#{user.id}_invalidation"
      end

      def cached?(user)
        !@store.read("pf:#{key_of(user)}").nil?
      end

      # Whether the store holds a hash for the user that differs from the database.
      def stale?(user)
        entry = @store.read("pf:#{key_of(user)}")
        return false if entry.nil?

        person = reader(user)
        fresh = PermissionForge::Services::PermissionHashBuilder.call(
          user: person, permission_sets: person.send(:pf_active_non_expired_permission_sets)
        )
        JSON.parse(entry[:permissions].to_json) != JSON.parse(fresh.to_json)
      end

      def reported
        @reported.map { |failure| failure.values_at(:operation, :user_id) }
      end
    end
  end
end
