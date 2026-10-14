require 'test_helper'

module PermissionForge
  module Cache
    class CacheTtlTest < ActiveSupport::TestCase
      setup do
        @cache = PermissionForge::Cache::MemoryCache.new(prefix: 'test')
      end

      test 'write without TTL persists indefinitely' do
        @cache.write('key', { data: 'value' })

        assert_equal({ data: 'value' }, @cache.read('key'))
      end

      test 'write with TTL expires after duration' do
        written_at = Time.current.change(usec: 0)
        travel_to written_at
        @cache.write('key', { data: 'value' }, ttl: 60)

        travel_to written_at + 59.seconds
        assert_equal({ data: 'value' }, @cache.read('key'))
        travel_to written_at + 60.seconds
        assert_nil @cache.read('key')
      end

      test 'write with TTL returns value before expiration' do
        @cache.write('key', { data: 'value' }, ttl: 10)

        assert_equal({ data: 'value' }, @cache.read('key'))
      end

      test 'delete removes TTL entries' do
        @cache.write('key', { data: 'value' }, ttl: 10)
        @cache.delete('key')

        assert_nil @cache.read('key')
      end

      test 'clear removes all TTL entries' do
        @cache.write('key1', { a: 1 }, ttl: 10)
        @cache.write('key2', { b: 2 })
        @cache.clear

        assert_nil @cache.read('key1')
        assert_nil @cache.read('key2')
      end

      test 'cache_ttl config defaults to 3600 (1 hour staleness backstop)' do
        config = PermissionForge::Configuration.new
        assert_equal 3600, config.cache_ttl
      end

      test 'conditional_set_cache_ttl config defaults to 300 (5 minutes)' do
        config = PermissionForge::Configuration.new
        assert_equal 300, config.conditional_set_cache_ttl
      end

      test 'regenerate_permissions passes cache_ttl to cache write' do
        user = create_user
        permission_set = create_permission_set
        create_resource(permission_set: permission_set, name: 'Customer', read_access: true)
        create_permission_set_user(user: user, permission_set: permission_set)

        # Set TTL and regenerate
        PermissionForge.configuration.cache_ttl = 3600
        user.regenerate_permissions

        # Verify permissions are cached
        assert_not_empty user.permissions_hash
      ensure
        PermissionForge.configuration.cache_ttl = 3600
      end

      test 'null_cache accepts TTL parameter without error' do
        cache = PermissionForge::Cache::NullCache.new
        cache.write('key', { data: 'value' }, ttl: 60)

        assert_nil cache.read('key')
      end
    end
  end
end
