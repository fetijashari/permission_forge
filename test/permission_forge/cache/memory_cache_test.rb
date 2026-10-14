require 'test_helper'

module PermissionForge
  module Cache
    class MemoryCacheTest < ActiveSupport::TestCase
      setup do
        @cache = PermissionForge::Cache::MemoryCache.new(prefix: 'test')
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

      test 'removes a key on delete' do
        @cache.write('user_1', { data: true })
        @cache.delete('user_1')
        assert_nil @cache.read('user_1')
      end

      test 'removes all keys on clear' do
        @cache.write('user_1', { a: 1 })
        @cache.write('user_2', { b: 2 })
        @cache.clear
        assert_nil @cache.read('user_1')
        assert_nil @cache.read('user_2')
      end

      test 'returns a deep copy so callers cannot mutate the cache' do
        @cache.write('user_1', { permissions: { resources: { Customer: true } } })
        first_read = @cache.read('user_1')
        first_read[:permissions][:resources][:Customer] = false

        second_read = @cache.read('user_1')
        assert second_read[:permissions][:resources][:Customer],
               'Mutating the returned hash should not affect the cached value'
      end

      test 'handles nested arrays and hashes' do
        data = { rules: [{ name: 'rule1', conditions: { field: 'email' } }] }
        @cache.write('user_1', data)
        result = @cache.read('user_1')

        assert_equal :rules, result.keys.first
        assert_equal :name, result[:rules].first.keys.first
        assert_equal 'rule1', result[:rules].first[:name]
        assert_equal 'email', result[:rules].first[:conditions][:field]
      end
    end
  end
end
