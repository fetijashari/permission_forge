require 'test_helper'

module PermissionForge
  module Cache
    class NullCacheTest < ActiveSupport::TestCase
      setup do
        @cache = PermissionForge::Cache::NullCache.new
      end

      test 'always returns nil on read' do
        @cache.write('key', { data: true })
        assert_nil @cache.read('key')
      end

      test 'does not raise on delete' do
        assert_nothing_raised { @cache.delete('key') }
      end

      test 'does not raise on clear' do
        assert_nothing_raised { @cache.clear }
      end
    end
  end
end
