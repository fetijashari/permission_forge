# frozen_string_literal: true

require 'test_helper'
require_relative '../cache/failing_store'

module PermissionForge
  module Services
    # R2 review, P2-5 and P2-6.
    #
    # "Deferred" has one reading, Cache::Report's (OpenTransaction.current
    # when the work is measured): inside a caller's transaction the consent
    # withdrawal and the clean-up report a pending outcome, as the bulk
    # assignment and the erasure do — not one confirmed before the commit.
    #
    # erasure.performed and consent.withdrawn are written before the cache
    # work (cache_confirmed: nil); cache.settled, on the same correlation id,
    # records what the store said once the work ran — after the caller's
    # commit when there is one. A failed post-commit invalidation of an
    # erased person leaves that trace.
    class CacheSettlementOutcomeTest < ActiveSupport::TestCase
      setup do
        @person = create_user(name: 'Pia')
        @set = create_permission_set(name: 'Marketing', requires_session_flag: 'marketing')
        create_permission_set_user(user: @person, permission_set: @set)
        @store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      def settled = PermissionForge::AuditEvent.where(event: 'cache.settled').order(:id)

      # --- P2-5 ------------------------------------------------------------------

      test 'inside a caller transaction a consent withdrawal reports deferred, not confirmed' do
        result = ActiveRecord::Base.transaction do
          ConsentWithdrawalHandler.call(user: @person, consent_flag: 'marketing')
        end

        assert_nil result[:cache][:confirmed], result[:cache].inspect
        assert_nil result[:invalidated]
      end

      test 'inside a caller transaction the clean-up reports deferred, not confirmed' do
        expiring = create_permission_set(name: 'Temp')
        create_permission_set_user(user: @person, permission_set: expiring, expires_at: 1.day.from_now)

        result = travel_to(2.days.from_now) do
          ActiveRecord::Base.transaction { ExpiredAssignmentCleaner.call }
        end

        assert_equal 1, result[:removed]
        assert_nil result[:cache][:confirmed], result[:cache].inspect
        assert_nil result[:invalidated]
      end

      test 'outside a transaction both still report what the store confirmed' do
        assert_equal true, ConsentWithdrawalHandler.call(user: @person, consent_flag: 'marketing')[:cache][:confirmed]
      end

      # --- P2-6 ------------------------------------------------------------------

      test 'an erasure records what the store said in cache.settled, on the erasure correlation id' do
        @store.down!

        assert_difference -> { settled.count }, 1 do
          DataSubjectErasure.call(user: @person)
        end

        performed = PermissionForge::AuditEvent.where(event: 'erasure.performed').order(:id).last
        event = settled.last
        assert_nil performed.data['cache_confirmed']
        assert_equal false, event.data['cache_confirmed']
        assert_equal 'erasure', event.data['operation']
        assert_equal @person.id.to_s, event.subject_user_id
        assert_equal performed.correlation_id, event.correlation_id
      end

      test 'a consent withdrawal records cache.settled once its invalidation ran' do
        assert_difference -> { settled.count }, 1 do
          ConsentWithdrawalHandler.call(user: @person, consent_flag: 'marketing')
        end

        withdrawn = PermissionForge::AuditEvent.where(event: 'consent.withdrawn').order(:id).last
        assert_equal true, settled.last.data['cache_confirmed']
        assert_equal 'consent_withdrawal', settled.last.data['operation']
        assert_equal withdrawn.correlation_id, settled.last.correlation_id
      end

      test 'inside a caller transaction cache.settled is written after the commit, with the outcome then' do
        @store.down!
        correlation = nil

        ActiveRecord::Base.transaction do
          DataSubjectErasure.call(user: @person)
          correlation = PermissionForge::AuditEvent.where(event: 'erasure.performed').order(:id).last.correlation_id
          assert_equal 0, settled.count, 'nothing is settled before the commit'
        end

        assert_equal 1, settled.count
        assert_equal false, settled.last.data['cache_confirmed'], 'the failed post-commit invalidation leaves a trace'
        assert_equal correlation, settled.last.correlation_id
      end

      test 'a rolled-back erasure settles nothing' do
        ActiveRecord::Base.transaction do
          DataSubjectErasure.call(user: @person)
          raise ActiveRecord::Rollback
        end

        assert_equal 0, settled.count
      end
    end
  end
end
