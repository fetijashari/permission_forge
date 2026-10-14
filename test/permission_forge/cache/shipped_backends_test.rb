require 'test_helper'

module PermissionForge
  module Cache
    # A cache file the gem never loads is a backend nobody can configure:
    # Cache::RedisCache sat in lib/ (and in the benchmarks docs) without being
    # required, selectable or compatible with the stamp writes. Every file in
    # lib/permission_forge/cache must be loaded at boot, and Redis goes
    # through RailsCache (Rails' RedisCacheStore).
    class ShippedBackendsTest < ActiveSupport::TestCase
      CACHE_DIR = File.expand_path('../../../lib/permission_forge/cache', __dir__)

      test 'every file in lib/permission_forge/cache is loaded at boot' do
        loaded = $LOADED_FEATURES.map { |path| File.expand_path(path) }
        unloaded = Dir[File.join(CACHE_DIR, '**', '*.rb')].reject { |file| loaded.include?(File.expand_path(file)) }

        assert_empty unloaded.map { |file| file.delete_prefix("#{CACHE_DIR}/") }, 'cache files the gem never loads'
      end

      test 'there is no RedisCache backend: Redis is a Rails cache store' do
        refute PermissionForge::Cache.const_defined?(:RedisCache, false)
        assert_raises(ArgumentError) { PermissionForge::Configuration.new.tap { |c| c.cache_backend = :redis }.cache_store }
      end
    end
  end
end
