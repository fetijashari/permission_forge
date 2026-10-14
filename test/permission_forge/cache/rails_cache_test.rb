require 'test_helper'
require 'tmpdir'

module PermissionForge
  module Cache
    class RailsCacheTest < ActiveSupport::TestCase
      setup do
        @store = ActiveSupport::Cache::MemoryStore.new
        @cache = PermissionForge::Cache::RailsCache.new(prefix: 'test', store: @store)
      end

      test 'stores and retrieves a value' do
        @cache.write('user_1', { name: 'Alice' })
        assert_equal({ name: 'Alice' }, @cache.read('user_1'))
      end

      test 'returns nil for missing keys' do
        assert_nil @cache.read('nonexistent')
      end

      test 'deep symbolizes keys on read' do
        @cache.write('user_1', { 'permissions' => { 'resources' => { 'Customer' => true } } })
        result = @cache.read('user_1')
        assert result.dig(:permissions, :resources, :Customer)
      end

      test 'handles nested arrays with symbolized keys' do
        @cache.write('user_1', { rules: [{ name: 'rule1', active: true }] })
        result = @cache.read('user_1')
        assert_equal 'rule1', result[:rules].first[:name]
      end

      test 'removes a key on delete' do
        @cache.write('user_1', { data: true })
        @cache.delete('user_1')
        assert_nil @cache.read('user_1')
      end

      # ActiveSupport stores answer false for "nothing there" and for "failed".
      test 'expunge confirms a removal the store did not confirm by overwriting the key' do
        calls = []
        store = @store
        %i[delete write].each do |name|
          original = store.method(name)
          store.define_singleton_method(name) do |*args, **options|
            calls << name
            original.call(*args, **options)
          end
        end
        @cache.write('user_1', { data: true })
        calls.clear

        assert @cache.expunge('user_1')
        assert_equal [:delete], calls, 'a confirmed delete is enough'

        assert @cache.expunge('user_1')
        assert_equal %i[delete delete write], calls, 'nothing was there: overwritten with an empty entry'
        assert_nil @cache.read('user_1')
        travel(PermissionForge::Cache::RailsCache::EMPTY_ENTRY_TTL + 1) { assert_not @store.exist?('test:user_1') }
      end

      test 'expunge says so when the store keeps neither the delete nor the overwrite' do
        @cache.write('user_1', { data: true })
        @store.define_singleton_method(:delete) { |*| false }
        @store.define_singleton_method(:write) { |*, **| nil }

        assert_equal false, @cache.expunge('user_1')
      end

      test 'read_fresh reads like read when the store keeps no local copy' do
        @cache.write('stamp', 'abc')

        assert_equal 'abc', @cache.read_fresh('stamp')
        assert_nil @cache.read_fresh('nonexistent')
      end

      # A file store with ActiveSupport's LocalCache strategy, as the Redis,
      # Memcached and Solid Cache stores have it: inside with_local_cache (the
      # Rack middleware wraps every request in one) a read is remembered, a
      # miss too. A second store object on the same directory stands in for
      # another process.
      class LocalCopyStore < ActiveSupport::Cache::FileStore
        prepend ActiveSupport::Cache::Strategy::LocalCache
      end

      test 'read_fresh reads past the local copy of a request' do
        Dir.mktmpdir do |dir|
          store = LocalCopyStore.new(dir)
          cache = PermissionForge::Cache::RailsCache.new(prefix: 'test', store: store)
          elsewhere = PermissionForge::Cache::RailsCache.new(prefix: 'test', store: LocalCopyStore.new(dir))

          store.with_local_cache do
            assert_nil cache.read('stamp')
            elsewhere.write('stamp', 'first')
            assert_nil cache.read('stamp'), 'precondition: the request remembers the miss'
            assert_equal 'first', cache.read_fresh('stamp')

            elsewhere.write('stamp', 'second')
            assert_equal 'second', cache.read_fresh('stamp')
            assert_nil cache.read('stamp'), 'what the request remembers is left alone'
          end
        end
      end

      test 'removes matching keys on clear' do
        @cache.write('user_1', { a: 1 })
        @cache.write('user_2', { b: 2 })
        @cache.clear
        assert_nil @cache.read('user_1')
        assert_nil @cache.read('user_2')
      end

      test 'clear removes only keys under the prefix, on a namespaced memory store too' do
        [ActiveSupport::Cache::MemoryStore.new, ActiveSupport::Cache::MemoryStore.new(namespace: 'app')].each do |store|
          cache = PermissionForge::Cache::RailsCache.new(prefix: 'pf', store: store)
          cache.write('user_1', { a: 1 })
          store.write('apfx_session', 'kept')
          store.write('pfx:other', 'kept')

          assert_nothing_raised { cache.clear }
          assert_nil cache.read('user_1')
          assert_equal 'kept', store.read('apfx_session'), 'a key that only contains the prefix stays'
          assert_equal 'kept', store.read('pfx:other'), 'a key that starts with the prefix but not "prefix:" stays'
        end
      end

      test 'clear on a namespaced file store removes only keys under the prefix' do
        Dir.mktmpdir do |dir|
          store = ActiveSupport::Cache::FileStore.new(dir, namespace: 'app')
          cache = PermissionForge::Cache::RailsCache.new(prefix: 'pf', store: store)
          cache.write('user_1', { a: 1 })
          store.write('apfx_session', 'kept')

          assert_nothing_raised { cache.clear }
          assert_nil cache.read('user_1')
          assert_equal 'kept', store.read('apfx_session')
        end
      end

      test 'does not raise when store does not support delete_matched' do
        store = ActiveSupport::Cache::MemoryStore.new
        def store.delete_matched(*)
          raise NotImplementedError, 'not supported'
        end
        cache = PermissionForge::Cache::RailsCache.new(prefix: 'test_no_dm', store: store)
        cache.write('key', { a: 1 })
        assert_nothing_raised { cache.clear }
      end

      test 'works with MemoryStore' do
        memory_cache = PermissionForge::Cache::RailsCache.new(prefix: 'mem', store: ActiveSupport::Cache::MemoryStore.new)
        memory_cache.write('key', { value: 42 })
        assert_equal({ value: 42 }, memory_cache.read('key'))
      end

      test 'works with NullStore' do
        null_cache = PermissionForge::Cache::RailsCache.new(prefix: 'null', store: ActiveSupport::Cache::NullStore.new)
        null_cache.write('key', { value: 42 })
        assert_nil null_cache.read('key')
      end

      test 'works with FileStore' do
        Dir.mktmpdir do |dir|
          file_cache = PermissionForge::Cache::RailsCache.new(prefix: 'file', store: ActiveSupport::Cache::FileStore.new(dir))
          file_cache.write('key', { value: 42 })
          assert_equal({ value: 42 }, file_cache.read('key'))
          file_cache.delete('key')
        end
      end

      test 'falls back to Rails.cache when no store is provided' do
        rails_backed = PermissionForge::Cache::RailsCache.new(prefix: 'rc')
        rails_backed.write('test', { hello: 'world' })
        assert_equal({ hello: 'world' }, rails_backed.read('test'))
      end
    end
  end
end
