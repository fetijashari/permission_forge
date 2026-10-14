require 'test_helper'

module PermissionForge
  module Services
    class ExpiredAssignmentCleanerTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
        create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
      end

      test 'removes expired assignments and returns count' do
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)

        result = ExpiredAssignmentCleaner.call
        assert_equal 1, result[:removed]
        assert_equal 0, PermissionForge::PermissionSetUser.count
      end

      test 'invalidates cached permissions for affected users' do
        # Create a non-expired assignment to establish access, then expire it
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        @user.regenerate_permissions
        assert @user.can_read?(:Customer)

        # Expire the assignment and run cleaner
        psu.update_columns(expires_at: 1.hour.ago)

        result = ExpiredAssignmentCleaner.call
        assert_equal 1, result[:invalidated]
        assert_not @user.can_read?(:Customer), 'should lose access after expired assignment cleanup'
      end

      test 'does not remove active assignments (nil expires_at)' do
        create_permission_set_user(user: @user, permission_set: @permission_set)

        result = ExpiredAssignmentCleaner.call
        assert_equal 0, result[:removed]
        assert_equal 1, PermissionForge::PermissionSetUser.count
      end

      test 'does not remove future assignments' do
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.week.from_now)

        result = ExpiredAssignmentCleaner.call
        assert_equal 0, result[:removed]
        assert_equal 1, PermissionForge::PermissionSetUser.count
      end

      test 'handles mixed expired and active assignments' do
        active_user = create_user(name: 'Active User')
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)
        create_permission_set_user(user: active_user, permission_set: @permission_set)

        result = ExpiredAssignmentCleaner.call
        assert_equal 1, result[:removed]
        assert_equal 1, result[:invalidated]
        assert_equal 1, PermissionForge::PermissionSetUser.count
      end

      test 'handles no expired assignments gracefully' do
        result = ExpiredAssignmentCleaner.call
        assert_equal 0, result[:removed]
        assert_equal 0, result[:invalidated]
      end

      test 'handles multiple expired assignments for same user' do
        other_set = create_permission_set(name: 'Other Set')
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)
        create_permission_set_user(user: @user, permission_set: other_set, expires_at: 2.hours.ago)

        result = ExpiredAssignmentCleaner.call
        assert_equal 2, result[:removed]
        assert_equal 1, result[:invalidated], 'should invalidate each user only once'
      end

      # An admin renews an assignment while the clean-up is running: only
      # rows that are still expired when they are destroyed go, and the
      # revoked event is a snapshot of the row as it was then.
      test 'an assignment renewed during the run is kept' do
        first = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 2.hours.ago)
        renewed = create_permission_set_user(user: create_user(name: 'Renewed'),
                                             permission_set: @permission_set, expires_at: 1.hour.ago)
        after_first_delete { PermissionForge::PermissionSetUser.where(id: renewed.id).update_all(expires_at: 1.month.from_now) }

        result = ExpiredAssignmentCleaner.call

        assert_equal 1, result[:removed]
        refute PermissionForge::PermissionSetUser.exists?(first.id)
        assert PermissionForge::PermissionSetUser.exists?(renewed.id), 'the renewed assignment must survive'
        assert_empty audit_events_for(renewed).where(event: 'assignment.revoked')
        summary = AuditEvent.where(event: 'cleanup.expired_assignments').order(:id).last
        assert_equal [@user.id.to_s], summary.data['affected_user_ids']
      end

      test 'the revoked event is a snapshot of the row when it was destroyed' do
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 2.hours.ago)
        edited = create_permission_set_user(user: create_user(name: 'Edited'), permission_set: @permission_set,
                                            expires_at: 1.hour.ago)
        after_first_delete { PermissionForge::PermissionSetUser.where(id: edited.id).update_all(reason: 'edited meanwhile') }

        ExpiredAssignmentCleaner.call

        revoked = audit_events_for(edited).where(event: 'assignment.revoked').sole
        assert_equal 'edited meanwhile', revoked.data.dig('snapshot', 'reason')
      end

      # MySQL keeps `data` in a TEXT column (64 KB): an unbounded id list
      # would not fit.
      test 'the summary event keeps the user count and at most AFFECTED_USER_IDS_LIMIT ids' do
        stub_const_limit(2) do
          3.times do |i|
            create_permission_set_user(user: create_user(name: "Expired #{i}"), permission_set: @permission_set,
                                       expires_at: 1.hour.ago)
          end

          ExpiredAssignmentCleaner.call
        end

        data = AuditEvent.where(event: 'cleanup.expired_assignments').order(:id).last.data
        assert_equal 3, data['affected_user_count']
        assert_equal 2, data['affected_user_ids'].size
        assert data['affected_user_ids_truncated']
      end

      # --- Dry run ---

      test 'dry_run returns info without removing' do
        create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)

        result = ExpiredAssignmentCleaner.call(dry_run: true)
        assert_equal 0, result[:removed]
        assert_equal 0, result[:invalidated]
        assert_equal 1, result[:expired_count]
        assert_includes result[:affected_user_ids], @user.id
        assert_equal 1, PermissionForge::PermissionSetUser.count, 'should NOT remove records in dry run'
      end

      private

      # Runs the block once, right after the cleaner's first DELETE: what
      # another request does while the clean-up is running (test setup only).
      def after_first_delete(&block)
        # quoted the way the adapter quotes it: "t" (SQLite, PostgreSQL), `t` (MySQL)
        quoted = PermissionForge::PermissionSetUser.connection.quote_table_name(PermissionForge::PermissionSetUser.table_name)
        delete = /\ADELETE FROM #{Regexp.escape(quoted)}/i
        done = false
        hook = lambda do |*, payload|
          next if done || !payload[:sql].to_s.match?(delete)

          done = true
          block.call
        end
        @delete_subscription = ActiveSupport::Notifications.subscribe('sql.active_record', hook)
      end

      def stub_const_limit(limit)
        original = ExpiredAssignmentCleaner::AFFECTED_USER_IDS_LIMIT
        ExpiredAssignmentCleaner.send(:remove_const, :AFFECTED_USER_IDS_LIMIT)
        ExpiredAssignmentCleaner.const_set(:AFFECTED_USER_IDS_LIMIT, limit)
        yield
      ensure
        ExpiredAssignmentCleaner.send(:remove_const, :AFFECTED_USER_IDS_LIMIT)
        ExpiredAssignmentCleaner.const_set(:AFFECTED_USER_IDS_LIMIT, original)
      end

      teardown do
        ActiveSupport::Notifications.unsubscribe(@delete_subscription) if @delete_subscription
      end
    end
  end
end
