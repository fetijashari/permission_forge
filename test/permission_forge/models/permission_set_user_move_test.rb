# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  # An assignment moved to another user (host code: `assignment.update!(user: other)`)
  # takes the set away from the previous holder: that holder's cached hash
  # must go too, and the event must say who lost the set (pre-release integrity review
  # m1 — the previous holder kept the grant until cache_ttl).
  class PermissionSetUserMoveTest < ActiveSupport::TestCase
    setup do
      @set = create_permission_set
      create_resource(permission_set: @set, name: 'Customer', read_access: true)
      @from = create_user(name: 'From')
      @to = create_user(name: 'To')
      @third = create_user(name: 'Third')
      @assignment = create_permission_set_user(user: @from, permission_set: @set)
    end

    test 'moving an assignment invalidates the previous holder as well as the new one' do
      assert User.find(@from.id).can_read?(:Customer)
      assert_not User.find(@to.id).can_read?(:Customer)

      @assignment.update!(user: @to)

      assert_not User.find(@from.id).can_read?(:Customer), 'the previous holder lost the set'
      assert User.find(@to.id).can_read?(:Customer)
    end

    test 'every holder an assignment passed through in one transaction is invalidated' do
      [@from, @to, @third].each { |user| User.find(user.id).permissions_hash }

      ActiveRecord::Base.transaction do
        @assignment.update!(user: @to)
        @assignment.update!(user: @third)
      end

      [@from, @to].each { |user| assert_not User.find(user.id).can_read?(:Customer), user.name }
      assert User.find(@third.id).can_read?(:Customer)
    end

    test 'the assignment.changed event of a move names the previous holder' do
      @assignment.update!(user: @to)

      event = assert_audit_event('assignment.changed', record_id: @assignment.id.to_s, subject_user_id: @to.id.to_s)
      assert_equal @from.id.to_s, event.data['previous_subject_user_id']
      assert_equal [@from.id, @to.id], event.data['changes']['user_id']
    end

    test 'a change that keeps the holder names no previous one' do
      @assignment.update!(expires_at: 1.day.from_now)

      event = assert_audit_event('assignment.changed', record_id: @assignment.id.to_s)
      assert_not event.data.key?('previous_subject_user_id')
    end

    # The independent review's cases: a note must survive a rolled-back
    # savepoint and reach the instance whose commit callbacks run.
    test 'a later move rolled back to a savepoint keeps the earlier move' do
      cache_all

      ActiveRecord::Base.transaction do
        @assignment.update!(user: @to)
        ActiveRecord::Base.transaction(requires_new: true) do
          @assignment.update!(user: @third)
          raise ActiveRecord::Rollback
        end
      end

      assert_not User.find(@from.id).can_read?(:Customer), 'the holder before the kept move'
      assert User.find(@to.id).can_read?(:Customer)
    end

    test 'a move made through another instance of the row reaches the instance that commits' do
      cache_all

      ActiveRecord::Base.transaction do
        PermissionSetUser.find(@assignment.id).update!(user: @to)
        PermissionSetUser.find(@assignment.id).update!(user: @third)
      end

      [@from, @to].each { |user| assert_not User.find(user.id).can_read?(:Customer), user.name }
      assert User.find(@third.id).can_read?(:Customer)
    end

    test 'a move followed by a destroy through another instance invalidates every holder' do
      cache_all

      ActiveRecord::Base.transaction do
        PermissionSetUser.find(@assignment.id).update!(user: @to)
        PermissionSetUser.find(@assignment.id).destroy!
      end

      [@from, @to].each { |user| assert_not User.find(user.id).can_read?(:Customer), user.name }
    end

    test 'a resource moved to another set and saved again invalidates the holders of the set it left' do
      other = create_permission_set(name: 'Other')
      resource = PermissionForge::Resource.find_by!(permission_set_id: @set.id, name: 'Customer')
      cache_all

      ActiveRecord::Base.transaction do
        resource.update!(permission_set: other)
        resource.update!(create_access: true)
      end

      assert_not User.find(@from.id).can_read?(:Customer), 'the holder of the set the resource left'
    end

    test 'a record takes the notes of its own row from the batch, not those of other records' do
      batch = PermissionForge::InvalidationBatch.new
      batch.note(:previous_user_id, [['PermissionForge::PermissionSetUser', @assignment.id], @third.id])
      batch.note(:previous_user_id, [['PermissionForge::PermissionSetUser', @assignment.id + 1], @to.id])
      batch.note(:previous_user_id, [['PermissionForge::PermissionSetRule', @assignment.id], @to.id])
      @assignment.instance_variable_set(:@pf_invalidation_batch, batch)

      assert_equal [@third.id], @assignment.send(:previous_values, 'user_id')
    ensure
      @assignment.instance_variable_set(:@pf_invalidation_batch, nil)
    end

    private

    def cache_all
      [@from, @to, @third].each { |user| User.find(user.id).permissions_hash }
    end
  end
end
