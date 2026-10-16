# frozen_string_literal: true

module PermissionForge
  # Boot warnings about a cache store that does not reach other processes.
  # Called by BootChecks once per boot; only the configuration and the
  # store's class are read. Each warning goes through Warnings.emit, which
  # decides the channel (in development the terminal as well as the log:
  # the boot logs before `bin/rails server` attaches its console logger, and
  # `bin/rails runner`, the console and `db:seed` never do).
  #
  # A store of its own in every process (Cache::Base#process_local?:
  # cache_backend = :memory, or Rails.cache / a store instance that is an
  # ActiveSupport MemoryStore): an invalidation reaches the cache of the
  # process that makes it, so a change made elsewhere (a console,
  # `bin/rails runner`, a rake task, another Puma worker) leaves this
  # process's cached permission hashes as they were until cache_ttl.
  #
  # Such a store, or one that keeps nothing (Cache::Base#keeps_entries?:
  # cache_backend = :null, a :null_store), also cannot carry the token
  # MaskingSync announces a newly masked model with, while a masking setting
  # takes its models from the Resource rows (MaskedModels.row_driven?). In
  # development MaskingSync re-reads the Resource names from the database
  # instead (MaskingSync.database_recheck?); elsewhere a model first named in
  # another process stays unmasked here until a restart.
  #
  # @api private
  module CacheWarnings
    # The remedies for masking that cannot be announced, in every warning.
    MASKING_REMEDIES = 'Use a cache store every process shares (Redis, Memcached, Solid Cache; ' \
                       'in development also :file_store), or include PermissionForge::Concerns::MaskedAttributes ' \
                       'in each model that holds personal data and set config.auto_apply_masked_attributes = false ' \
                       '(the recommended production setup), or list the models in ' \
                       'config.auto_apply_masked_attributes. See docs/masked-attributes.md.'

    module_function

    # @param config [Configuration]
    # @return [void]
    def call(config)
      if Rails.env.production?
        warn_in_production(config)
      elsif Rails.env.development?
        warn_in_development(config)
      end
    end

    def warn_in_production(config)
      cache = PermissionForge.cache
      if cache.process_local?
        Warnings.emit(:cache_process_local,
                      'WARNING: Using an in-process permission cache in production (cache_backend = :memory, or ' \
                      'Rails.cache is a :memory_store). Permissions will be inconsistent across Puma workers. ' \
                      'Configure config.cache_backend = :rails_cache with Redis, Memcached, or SolidCache.')
      end
      return unless unannounced_masking?(cache)

      Warnings.emit(:cache_unannounced_masking,
                    "WARNING: #{masking_setting} takes its models from the Resource rows, but the cache store is " \
                    "#{store_description(config, cache)}: it cannot tell the other processes that a Resource row " \
                    'names a new model. A model first named by a row committed in another process (another ' \
                    'worker, a console, a rake task) stays unmasked in this process until it restarts. ' \
                    "#{MASKING_REMEDIES}")
    end

    # Rails 8.0+ generates `config.cache_store = :memory_store` for
    # development (7.1/7.2: :memory_store after `bin/rails dev:cache`,
    # :null_store otherwise), and the generated initializer caches through
    # Rails.cache.
    def warn_in_development(config)
      cache = PermissionForge.cache
      Warnings.emit(:cache_stale_permissions, stale_permissions_warning(config)) if cache.process_local?
      Warnings.emit(:cache_development_masking, development_masking_warning(config, cache)) if unannounced_masking?(cache)
    end

    # Printed by every development process that boots (a server, a console,
    # `bin/rails runner`, `db:seed`), so it speaks of processes, not of
    # "this server".
    def stale_permissions_warning(config)
      "Development: the permission cache is #{store_description(config, PermissionForge.cache)}, " \
        'one per process. A permission change made in one process (a console, `bin/rails runner`, ' \
        "a rake task or db:seed) invalidates only that process's cache: a running server keeps the " \
        "permissions it has cached until cache_ttl (#{config.cache_ttl.inspect} s) or a restart. " \
        "Changes made in the server's own admin UI apply there at once. To share the cache between " \
        'processes, set config.cache_store = :file_store, "tmp/cache/store" in ' \
        'config/environments/development.rb (with config.cache_backend = :rails_cache), or set ' \
        'config.cache_backend = :null in development (no caching). See docs/configuration.md#cache-consistency.'
    end

    def development_masking_warning(config, cache)
      "Development: #{masking_setting} takes its models from the Resource rows, and the cache " \
        "store is #{store_description(config, cache)}: it cannot tell a running server that a Resource row " \
        'committed from a console, `bin/rails runner` or a rake task names a new model. In development ' \
        'the server re-reads the Resource names from the database instead (one query at most every ' \
        "#{MaskingSync::DATABASE_RECHECK} s); in production a process would mask such a model only after a " \
        "restart. #{MASKING_REMEDIES}"
    end

    # A row-driven masking setting with a store that cannot carry
    # MaskingSync's token to another process.
    def unannounced_masking?(cache)
      MaskedModels.row_driven? && (cache.process_local? || !cache.keeps_entries?)
    end

    def masking_setting
      config = PermissionForge.configuration
      names = { 'auto_apply_masked_attributes' => config.auto_apply_masked_attributes,
                'mask_virtual_attributes' => config.mask_virtual_attributes }
      on = names.reject { |_name, value| MaskedModels::OFF.include?(value) || value.is_a?(Array) }
      "auto-applied masking (#{on.map { |name, value| "#{name} = #{value.inspect}" }.join(', ')})"
    end

    def store_description(config, cache)
      return kept_nothing_description(config) unless cache.keeps_entries?

      case config.cache_backend
      when :memory then 'in memory (cache_backend = :memory)'
      when :rails_cache then 'an in-memory store (Rails.cache is a :memory_store, the Rails development default)'
      else 'an in-memory store (cache_backend is an ActiveSupport::Cache::MemoryStore)'
      end
    end

    def kept_nothing_description(config)
      case config.cache_backend
      when :null then 'one that keeps nothing (cache_backend = :null)'
      when :rails_cache then 'one that keeps nothing (Rails.cache is a :null_store)'
      else 'one that keeps nothing (cache_backend is an ActiveSupport::Cache::NullStore)'
      end
    end
  end
end
