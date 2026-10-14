module PermissionForge
  module Cache
    # In-process hash-backed cache. Intended for development, tests, and
    # single-process deployments. Thread-safe via a Mutex so concurrent Puma
    # threads can't corrupt the store, but still PROCESS-LOCAL: in a multi-worker
    # deployment each worker has its own copy, so prefer :rails_cache (Redis,
    # Memcached, SolidCache) in production. The engine logs a warning at boot if
    # this backend is used in Rails.env.production?.
    #
    # @api public
    class MemoryCache < Base
      def initialize(prefix: 'pf')
        super
        @store = {}
        @mutex = Mutex.new
      end

      def process_local?
        true
      end

      # The entry under `key` (a deep copy, keys symbolized); nil when there
      # is none or it has expired.
      #
      # @return [Object, nil]
      def read(key)
        entry = @mutex.synchronize { @store[prefixed_key(key)] }
        return nil if entry.nil?

        if entry.is_a?(Hash) && entry[:__expires_at__]
          if Time.now >= entry[:__expires_at__]
            @mutex.synchronize { @store.delete(prefixed_key(key)) }
            return nil
          end
          value = entry[:__value__]
        else
          value = entry
        end

        # deep_dup for deep copy — callers can't mutate the cached object.
        deep_symbolize(value.deep_dup)
      end

      # Stores a deep copy of `value`, expiring after `ttl` seconds (never
      # without one).
      #
      # @return [Object] the value
      def write(key, value, ttl: nil)
        # dup on write too, so a caller mutating the object after write can't
        # corrupt the stored copy.
        stored = value.deep_dup
        entry = ttl ? { __value__: stored, __expires_at__: Time.now + ttl } : stored
        @mutex.synchronize { @store[prefixed_key(key)] = entry }
        value
      end

      # @return [Object, nil] the entry removed, nil when there was none
      def delete(key)
        @mutex.synchronize { @store.delete(prefixed_key(key)) }
      end

      # Removes every entry of this process's store.
      #
      # @return [void]
      def clear
        @mutex.synchronize { @store.clear }
      end

      # rubocop:disable-next Naming/PredicateMethod -- removes the entries; the answer is whether the store could
      def purge_entries(namespace)
        regexp, = UserKeys.entry_patterns(namespace, prefix: prefix)
        @mutex.synchronize { @store.delete_if { |key, _entry| key.match?(regexp) } }
        true
      end
    end
  end
end
