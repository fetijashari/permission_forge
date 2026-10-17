# frozen_string_literal: true

require 'test_helper'
require_relative '../cache/failing_store'

module PermissionForge
  module Services
    # What the services answer when the cache store does not confirm an
    # invalidation: the truth. The database change is made either way; the
    # cached permissions may live until cache_ttl, and the result says so.
    #
    # The truth comes from the gem's own failure bookkeeping
    # (Cache::Failure.none?), not from what User#invalidate_permissions
    # returns: host apps override that method, and a real one ends in
    # `Rails.cache.delete(its_own_key)` — whose value is whether that other
    # entry existed.
    class UnconfirmedInvalidationResultsTest < ActiveSupport::TestCase
      setup do
        @users = Array.new(2) { |i| create_user(name: "Person #{i}") }
        @set = create_permission_set(requires_session_flag: 'marketing_consent')
        create_resource(permission_set: @set, name: 'Customer', read_access: true)

        @store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # --- DataSubjectErasure ------------------------------------------------------

      test 'erasure says the cache was cleared when the store confirmed it' do
        assign(@users.first)

        assert_equal true, DataSubjectErasure.call(user: @users.first)[:cache_cleared]
      end

      test 'erasure says the cache was not cleared when the store is down, and still erases' do
        assign(@users.first)
        @store.down!

        result = DataSubjectErasure.call(user: @users.first)

        assert_equal false, result[:cache_cleared]
        assert_equal 1, result[:assignments_removed]
        assert_not PermissionForge::PermissionSetUser.exists?(user_id: @users.first.id)
      end

      test 'erasure counts a host override that answers nothing as cleared' do
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          super(tenant_id: tenant_id)
          nil
        end

        assert_equal true, DataSubjectErasure.call(user: @users.first)[:cache_cleared]
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      # The reviewer's S7: inside a transaction of the host the assignments
      # are only gone for everybody else at its commit, and so are the cached
      # permissions. What the service saw at the call says nothing about that.
      test 'erasure inside a transaction does not claim to know whether the cache was cleared' do
        assign(@users.first)
        [true, false].each do |snapshots|
          PermissionForge.configuration.snapshot_transactions = snapshots

          result = ActiveRecord::Base.transaction { DataSubjectErasure.call(user: @users.first) }

          assert_nil result[:cache_cleared], "snapshot_transactions = #{snapshots}"
        end
      end

      # --- a host override whose value is its own business (the reviewer's S4, S5) -----------

      test 'an override that answers false with nothing failed does not make the results say failed' do
        @users.each { |user| assign(user, expires_at: 1.hour.ago) }
        with_host_override(answering: false) do
          ids = @users.map(&:id)
          assert_equal false, @users.first.invalidate_permissions

          assert_equal 2, ExpiredAssignmentCleaner.call[:invalidated]
          assert_equal 2, BulkPermissionSetAssignment.call(permission_set: @set, user_ids: ids, action: :assign)[:invalidated]
          withdrawn = ConsentWithdrawalHandler.call(user: @users.last, consent_flag: 'marketing_consent')
          assert_equal({ revoked_sets: 1, invalidated: true }, withdrawn.slice(:revoked_sets, :invalidated))
          assert_equal true, DataSubjectErasure.call(user: @users.first)[:cache_cleared]
        end
      end

      test 'an override that answers true with the store down does not make the results say done' do
        @users.each { |user| assign(user, expires_at: 1.hour.ago) }
        with_host_override(answering: true) do
          ids = @users.map(&:id)
          @store.down!
          assert_equal true, @users.first.invalidate_permissions

          assert_equal 0, ExpiredAssignmentCleaner.call[:invalidated]
          assert_equal 0, BulkPermissionSetAssignment.call(permission_set: @set, user_ids: ids, action: :assign)[:invalidated]
          withdrawn = ConsentWithdrawalHandler.call(user: @users.last, consent_flag: 'marketing_consent')
          assert_equal({ revoked_sets: 1, invalidated: false }, withdrawn.slice(:revoked_sets, :invalidated))
          assert_equal false, DataSubjectErasure.call(user: @users.first)[:cache_cleared]
        end
      end

      # --- BulkPermissionSetAssignment ---------------------------------------------

      test 'bulk assignment counts the invalidations the store confirmed' do
        ids = @users.map(&:id)

        assert_equal 2, BulkPermissionSetAssignment.call(permission_set: @set, user_ids: ids, action: :assign)[:invalidated]

        fail_for(@users.first)
        result = BulkPermissionSetAssignment.call(permission_set: @set, user_ids: ids, action: :revoke)

        assert_equal 2, result[:revoked]
        assert_equal 1, result[:invalidated]
      end

      # --- ExpiredAssignmentCleaner -------------------------------------------------

      test 'the cleaner counts the invalidations the store confirmed' do
        @users.each { |user| assign(user, expires_at: 1.hour.ago) }
        fail_for(@users.first)

        result = ExpiredAssignmentCleaner.call

        assert_equal 2, result[:removed]
        assert_equal 1, result[:invalidated]
      end

      # --- ConsentWithdrawalHandler --------------------------------------------------

      test 'consent withdrawal says whether the invalidation was confirmed' do
        @users.each { |user| assign(user) }
        fail_for(@users.first)

        failed = ConsentWithdrawalHandler.call(user: @users.first, consent_flag: 'marketing_consent')
        confirmed = ConsentWithdrawalHandler.call(user: @users.last, consent_flag: 'marketing_consent')
        nothing = ConsentWithdrawalHandler.call(user: @users.last, consent_flag: 'marketing_consent')

        assert_equal({ revoked_sets: 1, invalidated: false }, failed.slice(:revoked_sets, :invalidated))
        assert_equal({ revoked_sets: 1, invalidated: true }, confirmed.slice(:revoked_sets, :invalidated))
        assert_equal({ revoked_sets: 0, invalidated: false }, nothing.slice(:revoked_sets, :invalidated))
      end

      private

      def assign(user, **attrs)
        create_permission_set_user(user: user, permission_set: @set, **attrs)
      end

      # A host's override: `super`, then work of its own, whose value is what
      # the method returns (a real one ends in `Rails.cache.delete(own_key)`).
      def with_host_override(answering:)
        User.define_method(:invalidate_permissions) do |tenant_id: nil|
          super(tenant_id: tenant_id)
          answering
        end
        yield
      ensure
        User.send(:remove_method, :invalidate_permissions)
      end

      # The store fails every call that concerns this user, and no other.
      def fail_for(user)
        @store.fail_when = ->(_operation, key) { key.include?("user_#{user.id}") }
      end
    end
  end
end
