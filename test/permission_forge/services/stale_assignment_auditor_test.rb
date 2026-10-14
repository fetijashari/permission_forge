require 'test_helper'

module PermissionForge
  module Services
    class StaleAssignmentAuditorTest < ActiveSupport::TestCase
      setup do
        @user = create_user
        @permission_set = create_permission_set
      end

      test 'reports permanent assignments older than threshold' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 100.days.ago)

        result = StaleAssignmentAuditor.call(threshold_days: 90)

        assert_equal 1, result[:stale_count]
        assert_includes result[:affected_user_ids], @user.id
        assert_equal @permission_set.name, result[:assignments].first[:permission_set]
      end

      # The assignment is still there and still stale: it is reported, with
      # no set name, instead of the report raising.
      test 'reports a stale assignment whose set is gone without raising' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 100.days.ago)
        PermissionForge::PermissionSet.where(id: @permission_set.id).delete_all # a host's raw delete, test setup only

        result = StaleAssignmentAuditor.call(threshold_days: 90)

        assert_equal 1, result[:stale_count]
        assert_nil result[:assignments].first[:permission_set]
      end

      test 'ignores assignments within threshold' do
        create_permission_set_user(user: @user, permission_set: @permission_set)

        result = StaleAssignmentAuditor.call(threshold_days: 90)

        assert_equal 0, result[:stale_count]
      end

      test 'ignores assignments with expires_at (time-bound)' do
        psu = create_permission_set_user(
          user: @user,
          permission_set: @permission_set,
          expires_at: 1.year.from_now
        )
        psu.update_columns(created_at: 100.days.ago)

        result = StaleAssignmentAuditor.call(threshold_days: 90)

        assert_equal 0, result[:stale_count]
      end

      test 'respects custom threshold' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 15.days.ago)

        assert_equal 0, StaleAssignmentAuditor.call(threshold_days: 30)[:stale_count]
        assert_equal 1, StaleAssignmentAuditor.call(threshold_days: 10)[:stale_count]
      end

      test 'defaults to 90-day threshold' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 91.days.ago)

        result = StaleAssignmentAuditor.call

        assert_equal 90, result[:threshold_days]
        assert_equal 1, result[:stale_count]
      end

      test 'includes days_stale in assignment details' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 120.days.ago)

        result = StaleAssignmentAuditor.call
        assignment = result[:assignments].first

        assert_in_delta 120, assignment[:days_stale], 1
      end

      test 'an unreviewed old assignment is stale even when it was edited recently' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 120.days.ago, updated_at: 1.day.ago)

        row = StaleAssignmentAuditor.call[:assignments].first

        assert_equal psu.user_id, row[:user_id]
        assert_in_delta 120, row[:days_stale], 1
        assert_nil row[:reviewed_by_id]
      end

      test 'a review restarts the clock, and an old review makes it stale again' do
        reviewer = create_user(name: 'Reviewer')
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 300.days.ago)
        psu.mark_reviewed!(reviewer: reviewer)
        assert_equal 0, StaleAssignmentAuditor.call[:stale_count]

        psu.update_columns(reviewed_at: 100.days.ago)
        row = StaleAssignmentAuditor.call[:assignments].first
        assert_in_delta 100, row[:days_stale], 1
        assert_equal reviewer.id, row[:reviewed_by_id]
        assert_in_delta 100.days.ago.to_i, row[:last_reviewed_at].to_i, 5
      end

      test 'without the review columns staleness is measured from updated_at' do
        psu = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu.update_columns(created_at: 300.days.ago, reviewed_at: 1.day.ago, updated_at: 100.days.ago)
        assert_equal 0, StaleAssignmentAuditor.call[:stale_count]

        PermissionForge::PermissionSetUser.singleton_class.alias_method(:pf_kept_review_supported?, :review_supported?)
        PermissionForge::PermissionSetUser.define_singleton_method(:review_supported?) { false }
        begin
          result = StaleAssignmentAuditor.call
          assert_equal 1, result[:stale_count]
          assert_in_delta 100, result[:assignments].first[:days_stale], 1
        ensure
          replace_method(PermissionForge::PermissionSetUser.singleton_class, :review_supported?, PermissionForge::PermissionSetUser.singleton_class.instance_method(:pf_kept_review_supported?))
          PermissionForge::PermissionSetUser.singleton_class.remove_method(:pf_kept_review_supported?)
        end
      end

      test 'handles no assignments gracefully' do
        result = StaleAssignmentAuditor.call

        assert_equal 0, result[:stale_count]
        assert_empty result[:affected_user_ids]
        assert_empty result[:assignments]
      end

      test 'reports multiple stale assignments across users' do
        other_user = create_user(name: 'Other User')
        other_set = create_permission_set(name: 'Other Set')

        psu1 = create_permission_set_user(user: @user, permission_set: @permission_set)
        psu2 = create_permission_set_user(user: other_user, permission_set: other_set)
        psu1.update_columns(created_at: 100.days.ago)
        psu2.update_columns(created_at: 95.days.ago)

        result = StaleAssignmentAuditor.call

        assert_equal 2, result[:stale_count]
        assert_equal 2, result[:affected_user_ids].size
      end
    end
  end
end
