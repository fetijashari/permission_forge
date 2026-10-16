require 'test_helper'

module PermissionForge
  module Services
    class BulkPermissionSetAssignmentTest < ActiveSupport::TestCase
      setup do
        @permission_set = create_permission_set
        @user1 = create_user(name: 'User 1')
        @user2 = create_user(name: 'User 2')
        @user3 = create_user(name: 'User 3')
      end

      # --- Assign ---

      test 'assigns multiple users to a permission set' do
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user2.id, @user3.id],
          action: :assign
        )

        assert_equal 3, result[:assigned]
        assert_equal 0, result[:revoked]
        assert_equal 3, result[:invalidated]
        assert_equal 3, @permission_set.permission_set_users.count
      end

      test 'skips already-assigned users' do
        create_permission_set_user(user: @user1, permission_set: @permission_set)

        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user2.id],
          action: :assign
        )

        assert_equal 1, result[:assigned]
        assert_equal 2, @permission_set.permission_set_users.count
      end

      test 'handles string user_ids' do
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id.to_s, @user2.id.to_s],
          action: 'assign'
        )

        assert_equal 2, result[:assigned]
      end

      # --- Revoke ---

      test 'revokes multiple users from a permission set' do
        create_permission_set_user(user: @user1, permission_set: @permission_set)
        create_permission_set_user(user: @user2, permission_set: @permission_set)

        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user2.id],
          action: :revoke
        )

        assert_equal 2, result[:revoked]
        assert_equal 0, @permission_set.permission_set_users.count
      end

      test 'revoke handles non-assigned users gracefully' do
        create_permission_set_user(user: @user1, permission_set: @permission_set)

        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user2.id],
          action: :revoke
        )

        assert_equal 1, result[:revoked]
      end

      # --- Invalidation ---

      test 'invalidates cached permissions for all affected users' do
        create_resource(permission_set: @permission_set, name: 'Customer', read_access: true)

        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user2.id],
          action: :assign
        )

        assert_equal 2, result[:invalidated]
        assert @user1.permissions_hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
        assert @user2.permissions_hash.dig(:permissions, :resources, :Customer, :permissions, :read_access)
      end

      # --- Edge cases ---

      test 'handles empty user_ids array' do
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [],
          action: :assign
        )

        assert_equal 0, result[:assigned]
        assert_equal 0, result[:invalidated]
      end

      test 'deduplicates user_ids' do
        result = BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: [@user1.id, @user1.id, @user1.id],
          action: :assign
        )

        assert_equal 1, result[:assigned]
      end

      test 'raises error for invalid action' do
        assert_raises(ArgumentError) do
          BulkPermissionSetAssignment.call(
            permission_set: @permission_set,
            user_ids: [@user1.id],
            action: :invalid
          )
        end
      end

      # --- Invalidation: once per user (pre-release performance review MINOR-1) ---

      test 'each assigned or revoked user is invalidated once' do
        users = [@user1, @user2, @user3]

        stamps = stamp_writes { BulkPermissionSetAssignment.call(permission_set: @permission_set, user_ids: users.map(&:id), action: :assign) }
        assert_equal users.map { |user| "user_#{user.id}_invalidation" }.sort, stamps.sort

        stamps = stamp_writes { BulkPermissionSetAssignment.call(permission_set: @permission_set, user_ids: users.map(&:id), action: :revoke) }
        assert_equal users.map { |user| "user_#{user.id}_invalidation" }.sort, stamps.sort
      end

      test 'a user who already held the set is neither invalidated nor counted' do
        create_permission_set_user(user: @user1, permission_set: @permission_set)

        result = nil
        stamps = stamp_writes do
          result = BulkPermissionSetAssignment.call(permission_set: @permission_set, user_ids: [@user1.id, @user2.id], action: :assign)
        end

        assert_equal ["user_#{@user2.id}_invalidation"], stamps
        assert_equal({ assigned: 1, revoked: 0, invalidated: 1, cache: { confirmed: true, process_local: true, unconfirmed: 0, in_request: false } }, result)
      end

      # The audit event and the validations of each new assignment read its
      # set: the inverse hands them the set at hand (acts_as_tenant's own
      # tenant check of the association still queries, once per row).
      test 'an assignment created through the set is given the set, not a query for it' do
        assignment = @permission_set.permission_set_users.create!(uuid: SecureRandom.uuid, user: @user3)

        assert assignment.association(:permission_set).loaded?
        assert_same @permission_set, assignment.permission_set
      end

      test 'inside a transaction of the caller the users are invalidated at its commit, and the count is not known' do
        @user1.permissions_hash
        result = nil

        ActiveRecord::Base.transaction do
          result = BulkPermissionSetAssignment.call(permission_set: @permission_set, user_ids: [@user1.id], action: :assign)
          assert PermissionForge.cache.read(@user1.permission_cache_key), 'nothing is invalidated before the commit'
        end

        assert_nil result[:invalidated]
        assert_nil PermissionForge.cache.read(@user1.permission_cache_key)
      end

      test 'a revocation a callback refuses is neither counted nor invalidated' do
        [@user1, @user2].each { |user| create_permission_set_user(user: user, permission_set: @permission_set) }
        kept = @user1.id
        PermissionForge::PermissionSetUser.define_method(:destroy) { user_id == kept ? false : super() }

        result = BulkPermissionSetAssignment.call(permission_set: @permission_set, user_ids: [@user1.id, @user2.id], action: :revoke)

        assert_equal({ assigned: 0, revoked: 1, invalidated: 1, cache: { confirmed: true, process_local: true, unconfirmed: 0, in_request: false } }, result)
        assert PermissionForge::PermissionSetUser.exists?(user_id: kept, permission_set_id: @permission_set.id)
      ensure
        PermissionForge::PermissionSetUser.send(:remove_method, :destroy)
      end

      private

      # The invalidation stamps written inside the block, one entry per write
      # (the memory cache writes key by key, also inside write_many).
      def stamp_writes
        cache = PermissionForge.cache
        written = []
        original = cache.method(:write)
        cache.define_singleton_method(:write) do |key, value, **options|
          written << key if key.end_with?('_invalidation')
          original.call(key, value, **options)
        end
        yield
        written
      ensure
        cache.singleton_class.send(:remove_method, :write)
      end
    end
  end
end
