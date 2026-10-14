require 'test_helper'
require_relative '../../support/boot_test_helpers'

module PermissionForge
  module Services
    class DataSubjectErasureTest < ActiveSupport::TestCase
      include BootTestHelpers

      setup do
        @user = create_user
        @permission_set = create_permission_set
        @other_set = create_permission_set(name: 'Other Set')
        create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @permission_set)
        create_permission_set_user(user: @user, permission_set: @other_set)
        @user.regenerate_permissions
      end

      test 'removes all permission set assignments for user' do
        result = DataSubjectErasure.call(user: @user)

        assert_equal 2, result[:assignments_removed]
        assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count
      end

      test 'removes group assignments for user' do
        group = create_permission_set_group
        PermissionForge::PermissionSetGroupUser.create!(
          uuid: SecureRandom.uuid,
          user: @user,
          permission_set_group: group
        )

        result = DataSubjectErasure.call(user: @user)

        assert_equal 1, result[:group_assignments_removed]
        assert_equal 0, PermissionForge::PermissionSetGroupUser.where(user: @user).count
      end

      test 'clears cached permissions' do
        assert @user.can_read?(:Customer)

        DataSubjectErasure.call(user: @user)

        # The raw cache entry is removed; a subsequent read-through rebuild
        # reflects the erased state (no resources, no access).
        assert_nil PermissionForge.cache.read(@user.permission_cache_key)
        assert_not @user.can_read?(:Customer)
        assert_empty @user.permissions_hash.dig(:permissions, :resources)
      end

      test 'invokes on_erasure callback when provided' do
        callback_called_with = nil
        callback = ->(user) { callback_called_with = user }

        result = DataSubjectErasure.call(user: @user, on_erasure: callback)

        assert result[:callback_invoked]
        assert_equal @user, callback_called_with
      end

      test 'returns callback_invoked false when no callback' do
        result = DataSubjectErasure.call(user: @user)

        assert_equal false, result[:callback_invoked]
      end

      test 'does not affect other users' do
        other_user = create_user(name: 'Other User')
        create_permission_set_user(user: other_user, permission_set: @permission_set)

        DataSubjectErasure.call(user: @user)

        assert_equal 1, PermissionForge::PermissionSetUser.where(user: other_user).count
      end

      test 'handles user with no assignments gracefully' do
        fresh_user = create_user(name: 'Fresh User')

        result = DataSubjectErasure.call(user: fresh_user)

        assert_equal 0, result[:assignments_removed]
        assert_equal 0, result[:group_assignments_removed]
        assert result[:cache_cleared]
      end

      test 'raises ArgumentError when user is nil' do
        assert_raises(ArgumentError) do
          DataSubjectErasure.call(user: nil)
        end
      end

      # --- on_erasure and the caller's transaction ---

      test 'inside a caller transaction on_erasure runs once that transaction has committed' do
        open_when_called = []
        result = nil

        ActiveRecord::Base.transaction do
          result = DataSubjectErasure.call(user: @user, on_erasure: ->(_) { open_when_called << OpenTransaction.current.present? })
          assert_empty open_when_called, 'the host deletion must not run before the erasure is committed'
        end

        assert_equal [false], open_when_called
        assert_nil result[:callback_invoked], 'only known at the commit'
      end

      test 'on_erasure never runs when the caller rolls the erasure back' do
        calls = []

        ActiveRecord::Base.transaction do
          DataSubjectErasure.call(user: @user, on_erasure: ->(user) { calls << user })
          raise ActiveRecord::Rollback
        end

        assert_empty calls
        assert_equal 2, PermissionForge::PermissionSetUser.where(user: @user).count, 'the erasure was rolled back'
      end

      # Raising from Rails' commit would skip the after-commit work queued
      # behind it (other records' cache invalidations): the error is
      # reported and logged instead.
      test 'a deferred on_erasure that raises is reported, never raised from the commit' do
        reported = []
        subscriber = Object.new
        subscriber.define_singleton_method(:report) { |error, handled:, **| reported << [error.message, handled] }
        Rails.error.subscribe(subscriber)

        assert_nothing_raised do
          ActiveRecord::Base.transaction do
            DataSubjectErasure.call(user: @user, on_erasure: ->(_) { raise ArgumentError, 'host deletion failed' })
          end
        end

        assert_equal [['host deletion failed', true]], reported, 'caught by the gem, like OpenTransaction::CommitHook.run_detached'
        assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count, 'the erasure stands'
      ensure
        Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
      end

      test 'outside a transaction an on_erasure error propagates after the erasure' do
        error = assert_raises(ArgumentError) do
          DataSubjectErasure.call(user: @user, on_erasure: ->(_) { raise ArgumentError, 'host deletion failed' })
        end

        assert_equal 'host deletion failed', error.message
        assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count
      end

      # An events table installed before tenancy (no tenant column): the
      # events cannot be told apart by tenant, so the scrub covers them all,
      # as the model's own scope does, instead of failing on the column.
      test 'with a tenant set and no tenant column on the events table the scrub covers every event' do
        labelled = PermissionForge::Audit.record('report.generated', actor: { type: 'user', id: @user.id, label: 'Gone' },
                                                                     data: {})

        with_singleton_method(PermissionForge.configuration, :resolved_tenant_column, -> { :org_id }) do
          assert_nothing_raised { DataSubjectErasure.call(user: @user) }
        end

        assert_nil PermissionForge::AuditEvent.unscoped.find(labelled.id).actor_label
      end

      # --- Dry run ---

      test 'dry run returns counts without removing' do
        result = DataSubjectErasure.call(user: @user, dry_run: true)

        assert_equal true, result[:dry_run]
        assert_equal 2, result[:assignments_count]
        assert_equal 0, result[:group_assignments_count]
        assert_includes result[:permission_sets], @permission_set.name
        assert_includes result[:permission_sets], @other_set.name
        # Records still exist
        assert_equal 2, PermissionForge::PermissionSetUser.where(user: @user).count
      end

      test 'dry run lists the sets it can see and never raises on an assignment whose set is gone' do
        orphan_set = create_permission_set(name: 'Deleted behind our back')
        create_permission_set_user(user: @user, permission_set: orphan_set)
        PermissionForge::PermissionSet.where(id: orphan_set.id).delete_all # a host's raw delete, test setup only

        result = DataSubjectErasure.call(user: @user, dry_run: true)

        assert_equal 3, result[:assignments_count]
        assert_equal [@permission_set.name, @other_set.name].sort, result[:permission_sets].sort
      end

      test 'dry run does not clear cache' do
        DataSubjectErasure.call(user: @user, dry_run: true)

        assert_not_empty @user.permissions_hash
      end
    end
  end
end
