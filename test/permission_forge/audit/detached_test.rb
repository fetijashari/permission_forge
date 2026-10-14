# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Audit
    # Refusals and failed sign-ins are evidence of something that did not
    # happen: they must survive a rollback of whatever transaction they were
    # noticed in, and be written exactly once.
    class DetachedTest < ActiveSupport::TestCase
      setup do
        @set = create_permission_set(name: 'Locked')
      end

      test 'outside a transaction the event is written at once' do
        event = Detached.record('admin.lock_refused', record: @set)

        assert_kind_of PermissionForge::AuditEvent, event
        assert_equal 1, refusals.count
      end

      test 'an event noticed inside a transaction that rolls back is still written' do
        PermissionForge::PermissionSet.transaction do
          Detached.record('admin.lock_refused', record: @set)
          assert_equal 0, refusals.count, 'not written inside the transaction'
          raise ActiveRecord::Rollback
        end

        assert_equal 1, refusals.count
      end

      test 'an event noticed inside a transaction that commits is written once, after the commit' do
        PermissionForge::PermissionSet.transaction do
          Detached.record('admin.lock_refused', record: @set)
        end

        assert_equal 1, refusals.count
      end

      test 'a savepoint that rolls back hands the event to the outer transaction, which commits it' do
        PermissionForge::PermissionSet.transaction do
          PermissionForge::PermissionSet.transaction(requires_new: true) do
            Detached.record('admin.lock_refused', record: @set)
            raise ActiveRecord::Rollback
          end
          assert_equal 0, refusals.count, 'still inside a transaction that may roll back'
        end

        assert_equal 1, refusals.count
      end

      test 'a savepoint released into an outer transaction that rolls back still writes once' do
        PermissionForge::PermissionSet.transaction do
          PermissionForge::PermissionSet.transaction(requires_new: true) do
            Detached.record('admin.lock_refused', record: @set)
          end
          raise ActiveRecord::Rollback
        end

        assert_equal 1, refusals.count
      end

      test 'who, where and the request are those of the moment of the refusal' do
        admin = create_user(name: 'Ada Admin')
        PermissionForge::PermissionSet.transaction do
          Context.with(request_id: 'req-9', ip: '10.0.0.9', reason: 'why') do
            PermissionForge.with_audit_actor(user: admin, source: 'admin_ui') do
              Detached.record('admin.lock_refused', record: @set)
            end
          end
          raise ActiveRecord::Rollback
        end

        assert_audit_event('admin.lock_refused', actor_type: 'user', actor_id: admin.id.to_s, source: 'admin_ui',
                                                 request_id: 'req-9', ip: '10.0.0.9', reason: 'why')
      end

      test 'OpenTransaction#after_end runs once when the transaction ends, either way' do
        runs = []
        PermissionForge::PermissionSet.transaction do
          OpenTransaction.current.after_end { runs << :rolled_back }
          raise ActiveRecord::Rollback
        end
        PermissionForge::PermissionSet.transaction do
          OpenTransaction.current.after_end { runs << :committed }
        end

        assert_equal %i[rolled_back committed], runs
      end

      test 'OpenTransaction#after_end: a savepoint that rolls back hands the block to the transaction around it' do
        runs = []
        PermissionForge::PermissionSet.transaction do
          PermissionForge::PermissionSet.transaction(requires_new: true) do
            OpenTransaction.current.after_end { runs << :ended }
            raise ActiveRecord::Rollback
          end
          assert_empty runs
        end
        assert_equal [:ended], runs
      end

      test 'OpenTransaction#after_end never raises out of a commit or a rollback' do
        reports = []
        reporter = Rails.error
        reporter.define_singleton_method(:report) { |error, **| reports << error.message }
        assert_nothing_raised do
          PermissionForge::PermissionSet.transaction { OpenTransaction.current.after_end { raise 'after commit' } }
        end
        error = assert_raises(ArgumentError) do
          PermissionForge::PermissionSet.transaction do
            OpenTransaction.current.after_end { raise 'after rollback' }
            raise ArgumentError, 'own'
          end
        end
        assert_equal 'own', error.message
        assert_equal ['after commit', 'after rollback'], reports
      ensure
        reporter.singleton_class.send(:remove_method, :report)
      end

      test "a deferred write that fails never raises: the caller's own exception survives, a commit returns" do
        PermissionForge.configuration.audit_change_failure_strategy = :raise
        PermissionForge.configuration.audit_hook_failure_strategy = :raise
        store = PermissionForge::AuditEvent.method(:store!)
        replace_singleton_method(PermissionForge::AuditEvent, :store!) { |*| raise ActiveRecord::StatementInvalid, 'store down' }

        error = assert_raises(ArgumentError) do
          PermissionForge::PermissionSet.transaction do
            Detached.record('admin.lock_refused', record: @set)
            raise ArgumentError, "the caller's own error"
          end
        end
        assert_equal "the caller's own error", error.message

        assert_nothing_raised do
          PermissionForge::PermissionSet.transaction { Detached.record('admin.lock_refused', record: @set) }
        end
      ensure
        replace_singleton_method(PermissionForge::AuditEvent, :store!, store)
      end

      private

      def refusals
        PermissionForge::AuditEvent.where(event: 'admin.lock_refused', record_id: @set.id.to_s)
      end
    end
  end
end
