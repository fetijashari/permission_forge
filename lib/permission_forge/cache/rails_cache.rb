module PermissionForge
  module Cache
    # Wraps any ActiveSupport::Cache::Store backend.
    # Works with every cache store Rails supports out of the box:
    #   - :memory_store
    #   - :file_store
    #   - :mem_cache_store (Memcached)
    #   - :redis_cache_store (Redis)
    #   - :solid_cache_store (SolidCache / Rails 8)
    #   - :null_store
    #   - Any custom ActiveSupport::Cache::Store subclass
    #
    # By default, uses Rails.cache. You can also pass a specific store instance.
    #
    # @api public
    class RailsCache < Base
      # Seconds the empty entry written by #expunge lives.
      EMPTY_ENTRY_TTL = 1

      # @return [Hash{String => Object}] the entries found, by prefixed key, symbolized as #read does
      def read_multi(keys)
        cache_store.read_multi(*keys.map { |key| prefixed_key(key) }).transform_values { |value| deep_symbolize(value) }
      end

      # Whether the store writes many entries in one call of its own, rather
      # than ActiveSupport's default loop (which ignores each write's answer).
      # Anything that is not an ActiveSupport store (a wrapper) is written key
      # by key through its #write.
      def self.multi_write?(store)
        store.is_a?(ActiveSupport::Cache::Store) &&
          store.class.instance_method(:write_multi_entries).owner != ActiveSupport::Cache::Store
      end

      def initialize(prefix: 'pf', store: nil)
        super(prefix: prefix)
        @store = store
      end

      # The entry under `key` in the Rails store, keys symbolized; nil for a
      # miss (also what a store that failed the read answers).
      #
      # @return [Object, nil]
      def read(key)
        value = cache_store.read(prefixed_key(key))
        return nil if value.nil?

        deep_symbolize(value)
      end

      # Redis, Memcached and Solid Cache stores (and others built on
      # ActiveSupport's LocalCache strategy) remember every read of a request,
      # misses included. A nested local cache starts empty, so the read inside
      # it reaches the store; what the request remembers is left as it is.
      def read_fresh(key)
        store = cache_store
        return read(key) unless store.respond_to?(:with_local_cache)

        store.with_local_cache { read(key) }
      end

      # One round trip for all the keys (read_multi), past the request's
      # local copies as #read_fresh reads: a nested local cache starts empty.
      def read_many(keys)
        return {} if keys.empty?

        store = cache_store
        found = store.respond_to?(:with_local_cache) ? store.with_local_cache { read_multi(keys) } : read_multi(keys)
        keys.to_h { |key| [key, found[prefixed_key(key)]] }
      end

      # Writes `value` under `key`, expiring after `ttl` seconds (the store's
      # default expiry without one).
      #
      # @return [Boolean] the store's answer: false when it did not take it
      def write(key, value, ttl: nil)
        options = {}
        options[:expires_in] = ttl if ttl
        cache_store.write(prefixed_key(key), value, **options)
      end

      # Rails' :memory_store lives in each process.
      def process_local?
        cache_store.is_a?(ActiveSupport::Cache::MemoryStore)
      end

      # A :null_store keeps nothing (the Rails 7.1/7.2 development default
      # without `bin/rails dev:cache`).
      def keeps_entries?
        !cache_store.is_a?(ActiveSupport::Cache::NullStore)
      end

      # An explicit `expires_in: nil` overrides the store's default expiry.
      def write_permanent(key, value)
        cache_store.write(prefixed_key(key), value, expires_in: nil)
      end

      # @return [Boolean] the store's answer: false when there was nothing
      #   to remove, or the delete failed (see #expunge)
      def delete(key)
        cache_store.delete(prefixed_key(key))
      end

      # A delete that reports true removed the entry. One that reports false
      # either found nothing or failed (Redis, Memcached and Solid Cache stores
      # rescue their errors), so the key is overwritten with an empty entry
      # that expires at once: a write says plainly whether it succeeded, and a
      # read of that entry is a miss like any other.
      # rubocop:disable-next Naming/PredicateMethod -- removes the key; the answer is whether the store confirmed it
      def expunge(key)
        name = prefixed_key(key)
        store = cache_store
        return true if store.delete(name)

        store.write(name, nil, expires_in: EMPTY_ENTRY_TTL) ? true : false
      end

      # One round trip for all the entries when the store sends them together
      # (Redis pipelines them, Solid Cache writes them in one statement): its
      # answer is then the answer for every key. Any other store (memory,
      # file, Memcached, null) is written one key at a time through #write,
      # as Base does.
      def write_many(entries, ttl: nil, &)
        return super unless multi_write?
        return {} if entries.empty?

        written = write_multi(entries, ttl, &)
        entries.transform_values { written }
      end

      # Overwrites the keys with empty entries that expire at once (as
      # #expunge does when a delete reports nothing), in one #write_many: a
      # write says plainly whether it succeeded, where a multi-delete only
      # counts what it removed. It also replaces the request's local copy of
      # each entry, which ActiveSupport's LocalCache leaves in place for a
      # multi-delete (it only hooks single deletes): a later read in the same
      # request would still find the entry. A read of an empty entry is a
      # miss like any other.
      def expunge_many(keys, &)
        return super unless multi_write?

        write_many(keys.to_h { |key| [key, nil] }, ttl: EMPTY_ENTRY_TTL, &)
      end

      # Where the store writes many entries in one call, the keys are
      # overwritten in that one call (#expunge_many — whose answer is not
      # needed here); else one delete per key, as Base does.
      def delete_many(keys, &)
        return super unless multi_write?

        expunge_many(keys, &)
        nil
      end

      # Removes every entry under the prefix — where the store can match
      # keys: Redis, memory and file stores. Solid Cache and Memcached stores
      # have no delete_matched, so there this removes nothing and says so in
      # the log (it answers false). On those, invalidate the users instead
      # (User#invalidate_permissions), or change config.cache_key_prefix,
      # which leaves the old entries to expire.
      def clear
        cache_store.delete_matched(prefix_matcher)
      rescue NotImplementedError, ArgumentError
        # Log loudly rather than silently no-op, so a "revoke everyone now"
        # call isn't mistaken for success.
        Rails.logger&.warn(
          "[PermissionForge] cache clear removed nothing: #{cache_store.class} does not support " \
          'delete_matched (Solid Cache and Memcached stores do not). Invalidate the users instead ' \
          '(User#invalidate_permissions), or change config.cache_key_prefix and let the old entries expire.'
        )
        false
      end

      # Through the store's delete_matched: a Redis store takes a glob (its
      # only form; the stamps go with the bare keys), the memory and file
      # stores a Regexp (exact; the store's own namespace is put in front by
      # ActiveSupport). A store that has no delete_matched (Memcached, Solid
      # Cache) or refuses the matcher answers false. Whether the removal
      # reached the keys is checked by Base#clear_entries.
      def purge_entries(namespace)
        entry_matchers(namespace).each { |matcher| cache_store.delete_matched(matcher) }
        true
      rescue NotImplementedError, ArgumentError
        false
      end

      private

      # A Redis store takes globs (its only form); the memory and file stores a Regexp (exact).
      def entry_matchers(namespace)
        regexp, globs = UserKeys.entry_patterns(namespace, prefix: prefix)
        redis_store? ? globs : [regexp]
      end

      # Every key under the prefix: a glob for Redis; for the memory and file
      # stores a Regexp anchored with `^` (the anchor ActiveSupport keeps when
      # it puts the store's own namespace in front). A String there would be
      # read as an unanchored Regexp ("pf:*" matches any key containing "pf")
      # and raises on a namespaced store.
      def prefix_matcher
        redis_store? ? "#{prefix}:*" : /^#{Regexp.escape(prefix)}:/
      end

      def redis_store?
        cache_store.class.name.to_s.include?('Redis')
      end

      def cache_store
        @store || rails_cache
      end

      def multi_write?
        self.class.multi_write?(cache_store)
      end

      # Whether the store took all the entries (HandledErrors.written); the
      # error it handed its error handler, or raised, is yielded.
      def write_multi(entries, ttl)
        options = ttl ? { expires_in: ttl } : {}
        store = cache_store
        written, error = HandledErrors.written(store) do
          store.write_multi(entries.transform_keys { |key| prefixed_key(key) }, options)
        end
        yield error if error && block_given?
        written
      rescue StandardError => e
        yield e if block_given?
        false
      end

      def rails_cache
        raise 'Rails.cache is not available. Pass a store: option or ensure Rails is loaded.' unless defined?(Rails) && Rails.respond_to?(:cache)

        Rails.cache
      end
    end
  end
end
