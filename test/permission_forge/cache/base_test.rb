require 'test_helper'

module PermissionForge
  module Cache
    class BaseTest < ActiveSupport::TestCase
      setup do
        @cache = PermissionForge::Cache::Base.new
      end

      test 'read raises NotImplementedError' do
        assert_raises(NotImplementedError) { @cache.read('key') }
      end

      test 'read_fresh is read unless a backend says otherwise' do
        assert_raises(NotImplementedError) { @cache.read_fresh('key') }
        assert_equal 'value', PermissionForge::Cache::MemoryCache.new.tap { |c| c.write('key', 'value') }.read_fresh('key')
        assert_nil PermissionForge::Cache::NullCache.new.read_fresh('key')
      end

      test 'expunge deletes, and only a delete that says false is not confirmed' do
        memory = PermissionForge::Cache::MemoryCache.new
        memory.write('key', 'value')

        assert memory.expunge('key')
        assert_nil memory.read('key')
        assert memory.expunge('never there')
        assert PermissionForge::Cache::NullCache.new.expunge('key')

        memory.define_singleton_method(:delete) { |_key| false }
        assert_not memory.expunge('key')
      end

      test 'write raises NotImplementedError' do
        assert_raises(NotImplementedError) { @cache.write('key', 'value') }
      end

      test 'delete raises NotImplementedError' do
        assert_raises(NotImplementedError) { @cache.delete('key') }
      end

      test 'clear raises NotImplementedError' do
        assert_raises(NotImplementedError) { @cache.clear }
      end

      test 'accepts a custom prefix' do
        cache = PermissionForge::Cache::Base.new(prefix: 'custom')
        assert_equal 'custom', cache.prefix
      end
    end
  end
end
