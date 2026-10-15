# frozen_string_literal: true

module PermissionForge
  # Boot warnings about a permission cache that lives in each process
  # (Cache::Base#process_local?: cache_backend = :memory, or Rails.cache /
  # a store instance that is an ActiveSupport MemoryStore). Called by
  # BootChecks once per boot; only the configuration and the store's class
  # are read.
  #
  # An invalidation reaches the cache of the process that makes it. With a
  # store of its own in every process, a change made elsewhere (a console,
  # `bin/rails runner`, a rake task, another Puma worker) leaves this
  # process's cached permission hashes as they were until cache_ttl. A
  # NullStore caches nothing and is never warned about.
  #
  # @api private
  module CacheWarnings
    module_function

    # @param config [Configuration]
    # @return [void]
    def warn_process_local_cache(config)
      return unless PermissionForge.cache.process_local?

      if Rails.env.production?
        warn_in_production
      elsif Rails.env.development?
        warn_in_development(config)
      end
    end

    def warn_in_production
      Rails.logger&.warn '[PermissionForge] WARNING: Using an in-process permission cache in production ' \
                         '(cache_backend = :memory, or Rails.cache is a :memory_store). ' \
                         'Permissions will be inconsistent across Puma workers. ' \
                         'Configure config.cache_backend = :rails_cache with Redis, Memcached, or SolidCache.'
    end

    # Rails 8.0+ generates `config.cache_store = :memory_store` for
    # development (7.1/7.2: :memory_store after `bin/rails dev:cache`,
    # :null_store otherwise), and the generated initializer caches through
    # Rails.cache.
    def warn_in_development(config)
      Rails.logger&.warn "[PermissionForge] Development: the permission cache is #{store_description(config)}, " \
                         'one per process. A permission change made from a console, `bin/rails runner` or a rake ' \
                         "task invalidates only that process's cache: this server keeps the permissions it has " \
                         "cached until cache_ttl (#{config.cache_ttl.inspect} s) or a restart. Changes made in " \
                         "this server's admin UI apply at once. To share the cache between processes, set " \
                         'config.cache_store = :file_store, "tmp/cache/store" in config/environments/development.rb ' \
                         '(with config.cache_backend = :rails_cache), or set config.cache_backend = :null ' \
                         'in development (no caching). See docs/configuration.md#cache-consistency.'
    end

    def store_description(config)
      case config.cache_backend
      when :memory then 'in memory (cache_backend = :memory)'
      when :rails_cache then 'an in-memory store (Rails.cache is a :memory_store, the Rails development default)'
      else 'an in-memory store (cache_backend is an ActiveSupport::Cache::MemoryStore)'
      end
    end
  end
end
