require 'test_helper'

module PermissionForge
  module Concerns
    class ExpirationIntegrationTest < ActiveSupport::TestCase
      setup do
        @user = create_user
      end

      # --- regenerate_permissions filters expired assignments ---

      test 'expired assignment is excluded from permission hash' do
        expired_set = create_permission_set(name: 'Expired Set')
        create_permission_set_user(user: @user, permission_set: expired_set, expires_at: 1.hour.ago)
        create_resource(permission_set: expired_set, name: 'Customer', read_access: true, delete_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'expired set should not grant read'
        assert_not @user.can_delete?(:Customer), 'expired set should not grant delete'
      end

      test 'future assignment is included in permission hash' do
        future_set = create_permission_set(name: 'Future Set')
        create_permission_set_user(user: @user, permission_set: future_set, expires_at: 1.week.from_now)
        create_resource(permission_set: future_set, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'future set should grant read'
      end

      test 'nil expires_at assignment is included in permission hash' do
        permanent_set = create_permission_set(name: 'Permanent Set')
        create_permission_set_user(user: @user, permission_set: permanent_set)
        create_resource(permission_set: permanent_set, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'permanent set should grant read'
      end

      # --- Mix of expired and active assignments ---

      test 'user retains access from active set when another set expires' do
        active_set = create_permission_set(name: 'Active Set')
        create_permission_set_user(user: @user, permission_set: active_set)
        create_resource(permission_set: active_set, name: 'Customer', read_access: true)

        expired_set = create_permission_set(name: 'Expired Set')
        create_permission_set_user(user: @user, permission_set: expired_set, expires_at: 1.hour.ago)
        create_resource(permission_set: expired_set, name: 'Customer', read_access: true, delete_access: true)

        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'active set read still works'
        assert_not @user.can_delete?(:Customer), 'expired set delete should not apply'
      end

      test 'user loses all access when all assignments expire' do
        set_a = create_permission_set(name: 'Set A')
        create_permission_set_user(user: @user, permission_set: set_a, expires_at: 2.hours.ago)
        create_resource(permission_set: set_a, name: 'Customer', read_access: true)

        set_b = create_permission_set(name: 'Set B')
        create_permission_set_user(user: @user, permission_set: set_b, expires_at: 1.hour.ago)
        create_resource(permission_set: set_b, name: 'Customer', read_access: true, edit_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'all sets expired'
        assert_not @user.can_edit?(:Customer), 'all sets expired'
      end

      # --- Expiration + muting interaction ---

      test 'expired muting set does not revoke permissions' do
        granting_set = create_permission_set(name: 'Granting')
        create_permission_set_user(user: @user, permission_set: granting_set)
        create_resource(permission_set: granting_set, name: 'Customer',
                        read_access: true, delete_access: true)

        muting_set = create_permission_set(name: 'Muting', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting_set, expires_at: 1.hour.ago)
        create_resource(permission_set: muting_set, name: 'Customer', delete_access: true)

        @user.regenerate_permissions
        assert @user.can_delete?(:Customer), 'muting set expired, should not revoke delete'
      end

      test 'active muting set still revokes permissions' do
        granting_set = create_permission_set(name: 'Granting')
        create_permission_set_user(user: @user, permission_set: granting_set)
        create_resource(permission_set: granting_set, name: 'Customer',
                        read_access: true, delete_access: true)

        muting_set = create_permission_set(name: 'Muting', is_muting: true)
        create_permission_set_user(user: @user, permission_set: muting_set, expires_at: 1.week.from_now)
        create_resource(permission_set: muting_set, name: 'Customer', delete_access: true)

        @user.regenerate_permissions
        assert_not @user.can_delete?(:Customer), 'active muting set should revoke delete'
      end

      # --- Inactive set vs expired assignment ---

      test 'inactive permission set is excluded regardless of assignment expiration' do
        inactive_set = create_permission_set(name: 'Inactive', is_active: false)
        create_permission_set_user(user: @user, permission_set: inactive_set)
        create_resource(permission_set: inactive_set, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        assert_not @user.can_read?(:Customer), 'inactive set excluded even with active assignment'
      end

      # --- Multiple users: expiration is per-assignment ---

      test 'expiration only affects the assigned user' do
        other_user = create_user(name: 'Other User')
        shared_set = create_permission_set(name: 'Shared')

        create_permission_set_user(user: @user, permission_set: shared_set, expires_at: 1.hour.ago)
        create_permission_set_user(user: other_user, permission_set: shared_set)
        create_resource(permission_set: shared_set, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        other_user.regenerate_permissions

        assert_not @user.can_read?(:Customer), 'expired user loses access'
        assert other_user.can_read?(:Customer), 'other user retains access'
      end

      # --- source_permission_sets reflects expiration ---

      test 'expired assignments are not in source_permission_sets' do
        active_set = create_permission_set(name: 'Active Set')
        create_permission_set_user(user: @user, permission_set: active_set)
        create_resource(permission_set: active_set, name: 'Customer', read_access: true)

        expired_set = create_permission_set(name: 'Expired Set')
        create_permission_set_user(user: @user, permission_set: expired_set, expires_at: 1.hour.ago)
        create_resource(permission_set: expired_set, name: 'Customer', read_access: true)

        @user.regenerate_permissions
        sources = @user.permissions_hash.dig(:permissions, :resources, :Customer, :source_permission_sets)
        source_uuids = sources.map { |s| s[:uuid] }

        assert_includes source_uuids, active_set.uuid
        assert_not_includes source_uuids, expired_set.uuid, 'expired set should not be in sources'
      end
    end
  end
end
