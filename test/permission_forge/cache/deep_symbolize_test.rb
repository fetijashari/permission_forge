require 'test_helper'

module PermissionForge
  module Cache
    # Stores hand back string keys (JSON) or the hash as written; every
    # backend reads the permission hash with symbol keys.
    class DeepSymbolizeTest < ActiveSupport::TestCase
      setup do
        @cache = PermissionForge::Cache::MemoryCache.new(prefix: 'test')
      end

      test 'deep_symbolize handles mixed string and symbol keys' do
        input = { 'name' => 'Alice', status: 'active', 'nested' => { 'deep' => true } }
        result = @cache.send(:deep_symbolize, input)

        assert_equal({ name: 'Alice', status: 'active', nested: { deep: true } }, result)
      end

      test 'deep_symbolize walks arrays of hashes' do
        input = { 'rules' => [{ 'name' => 'own rows' }, 'plain'] }

        assert_equal({ rules: [{ name: 'own rows' }, 'plain'] }, @cache.send(:deep_symbolize, input))
      end
    end
  end
end
