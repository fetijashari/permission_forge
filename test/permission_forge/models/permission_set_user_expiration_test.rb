require 'test_helper'

module PermissionForge
  class PermissionSetUserExpirationTest < ActiveSupport::TestCase
    setup do
      @user = create_user
      @permission_set = create_permission_set
    end

    # --- Instance methods ---

    test 'expired? returns false when expires_at is nil' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set)
      assert_not psu.expired?
    end

    test 'expired? returns false when expires_at is in the future' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.day.from_now)
      assert_not psu.expired?
    end

    test 'expired? returns true when expires_at is in the past' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.day.ago)
      assert psu.expired?
    end

    test 'active_assignment? returns true when not expired' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set)
      assert psu.active_assignment?
    end

    test 'active_assignment? returns true when expires_at is in the future' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.from_now)
      assert psu.active_assignment?
    end

    test 'active_assignment? returns false when expired' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)
      assert_not psu.active_assignment?
    end

    # --- Scopes ---

    test '.active_assignments returns records with nil expires_at' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set)
      assert_includes PermissionForge::PermissionSetUser.active_assignments, psu
    end

    test '.active_assignments returns records with future expires_at' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.week.from_now)
      assert_includes PermissionForge::PermissionSetUser.active_assignments, psu
    end

    test '.active_assignments excludes records with past expires_at' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.hour.ago)
      assert_not_includes PermissionForge::PermissionSetUser.active_assignments, psu
    end

    test '.expired returns only records with past expires_at' do
      active_psu = create_permission_set_user(user: @user, permission_set: @permission_set)
      expired_psu = create_permission_set_user(
        user: create_user(name: 'Other'),
        permission_set: @permission_set,
        expires_at: 1.hour.ago
      )

      expired_scope = PermissionForge::PermissionSetUser.expired
      assert_includes expired_scope, expired_psu
      assert_not_includes expired_scope, active_psu
    end

    test '.expired excludes records with nil expires_at' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set)
      assert_not_includes PermissionForge::PermissionSetUser.expired, psu
    end

    test '.expired excludes records with future expires_at' do
      psu = create_permission_set_user(user: @user, permission_set: @permission_set, expires_at: 1.week.from_now)
      assert_not_includes PermissionForge::PermissionSetUser.expired, psu
    end
  end
end
