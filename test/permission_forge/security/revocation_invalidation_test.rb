# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # End-to-end regression tests for the headline finding: revoking a user's
    # access must take effect at runtime, not only in the database. Every
    # assign/revoke path (model, single API/UI destroy, whole-set destroy) must
    # invalidate the user's cached permission hash so the next check reflects it.
    class RevocationInvalidationTest < ActionDispatch::IntegrationTest
      setup do
        @user = create_user
        @ps = create_permission_set
        @psu = create_permission_set_user(user: @user, permission_set: @ps)
        create_resource(permission_set: @ps, name: 'Customer', read_access: true)
        @user.regenerate_permissions
        assert @user.can_read?(:Customer), 'precondition: user has access'
      end

      test 'destroying the PermissionSetUser model invalidates the cache' do
        @psu.destroy!
        assert_nil PermissionForge.cache.read(@user.permission_cache_key), 'cache entry removed'
        assert_not @user.can_read?(:Customer), 'access gone after read-through rebuild'
      end

      test 'API single-user revoke invalidates the cache (revoked access actually gone)' do
        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/users/#{@psu.uuid}"
        assert_response :no_content

        assert_nil PermissionForge.cache.read(@user.permission_cache_key)
        assert_not @user.reload.can_read?(:Customer)
      end

      test 'destroying the whole PermissionSet revokes access for its users' do
        other = create_user(name: 'Other')
        create_permission_set_user(user: other, permission_set: @ps)
        other.regenerate_permissions
        assert other.can_read?(:Customer)

        @ps.destroy!

        assert_not @user.can_read?(:Customer)
        assert_not other.can_read?(:Customer)
      end

      test 'assigning a set via API takes effect on next read' do
        fresh = create_user(name: 'Fresh')
        refute fresh.can_read?(:Customer)

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/users", params: { user_id: fresh.id }
        assert_response :created

        assert fresh.can_read?(:Customer), 'newly assigned user gains access without manual regenerate'
      end

      test 'expired assignment stops granting from cache once TTL clamps to expiry' do
        # New assignment expiring in 1 second; TTL should clamp to ~1s.
        soon = create_user(name: 'Soon')
        create_permission_set_user(user: soon, permission_set: @ps, expires_at: 1.second.from_now)
        soon.regenerate_permissions
        assert soon.can_read?(:Customer)

        ttl = PermissionForge.configuration.cache_ttl
        assert_operator ttl, :>, 1, 'baseline TTL is larger than the expiry'
        # The effective cache TTL must have been clamped to the near expiry, not the 1h baseline.
        # (We assert the clamp logic directly to avoid a real sleep.)
        computed = soon.send(:pf_permission_cache_ttl, PermissionForge::PermissionSet.where(id: @ps.id))
        assert_operator computed, :<=, 2, 'TTL clamped to soonest expiry'
      end
    end
  end
end
