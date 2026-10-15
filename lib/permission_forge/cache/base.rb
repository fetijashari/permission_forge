module PermissionForge
  # The permission cache backends (Base and its subclasses, config.cache_backend) and the
  # machinery that invalidates and rebuilds cached permission hashes. The backends are public;
  # each class says which it is (a public namespace does not make its children public).
  #
  # @api public
  module Cache
    # The interface a cache backend implements (config.cache_backend accepts a subclass):
    # read/write/delete/clear, plus what the gem builds on them — #read_fresh, #expunge, the
    # multi-key calls and the removal of permission entries by pattern (#clear_entries).
    #
    # @api public
    class Base
      # @return [String] put in front of every key, with a colon (config.cache_key_prefix)
      attr_reader :prefix

      def initialize(prefix: 'pf')
        @prefix = prefix
      end

      def read(key)
        raise NotImplementedError
      end

      # Reads `key` from the store itself. A store that keeps a copy of what a
      # request has read (ActiveSupport's local cache) answers a repeated read
      # from that copy — also a miss; a value another process may have written
      # in the meantime has to be read past it. Backends without such a copy
      # read as usual.
      def read_fresh(key)
        read(key)
      end

      # @return [Object] something truthy when the value was written; false or
      #   nil when the store reports that it was not (ActiveSupport stores
      #   answer that instead of raising when they are unreachable)
      def write(key, value, ttl: nil)
        raise NotImplementedError
      end

      # Whether every process has a store of its own (an in-memory store):
      # clearing or writing it here reaches no other process.
      #
      # @return [Boolean]
      def process_local?
        false
      end

      # Whether the store keeps what is written to it. A store that keeps
      # nothing (cache_backend = :null, a :null_store) caches no permission
      # hash, and cannot carry the token MaskingSync tells other processes
      # about a newly masked model with.
      #
      # @return [Boolean]
      def keeps_entries?
        true
      end

      # Writes an entry that never expires — not even under a default expiry
      # the store applies to every entry (a Rails cache configured with
      # expires_in). Here a write without a TTL, which is that already.
      #
      # @return [Object] as #write
      def write_permanent(key, value)
        write(key, value)
      end

      def delete(key)
        raise NotImplementedError
      end

      # Removes `key` and says whether it is certainly gone. `delete` alone
      # cannot say that for a store that swallows its errors: it answers false
      # both for "there was nothing to delete" and for "the delete failed"
      # (RailsCache#expunge deals with that). A backend that can only fail by
      # raising is taken at its word unless its delete says false.
      #
      # @return [Boolean] false when the store could not confirm the removal
      # rubocop:disable-next Naming/PredicateMethod -- removes the key; the answer is whether the store confirmed it
      def expunge(key)
        delete(key) != false
      end

      def clear
        raise NotImplementedError
      end

      # Removes every permission entry of one key namespace — the base
      # entries of every user and tenant, and their variants
      # (UserKeys.entry_patterns) — where the store can match keys
      # (#purge_entries), and says whether it did. Verified, not taken on
      # trust: an entry of each key shape (UserKeys.canary_keys) is written
      # before and read back after; a pattern that did not reach the store's
      # keys (a store namespace the pattern does not know) leaves them, and
      # the answer is false. False also when the backend cannot match keys,
      # or the canaries could not be written: the caller enumerates the
      # users instead (Services::PermissionCacheClearer).
      #
      # @param namespace [String] one of UserKeys.namespaces
      # @return [Boolean]
      def clear_entries(namespace)
        canaries = UserKeys.canary_keys(namespace)
        return false unless canaries.all? { |key| write(key, CANARY_ENTRY, ttl: CANARY_TTL) }
        return false unless purge_entries(namespace)

        canaries.none? { |key| read_fresh(key) }
      ensure
        canaries&.each { |key| delete(key) }
      end

      # What a canary entry holds, and how long it may live if left behind.
      CANARY_ENTRY = { canary: true }.freeze
      CANARY_TTL = 60

      # Removes the entries matching UserKeys.entry_patterns in one call per
      # pattern, where the backend can. Here it cannot.
      #
      # @return [Boolean] whether the backend could
      # rubocop:disable-next Naming/PredicateMethod -- removes the entries; the answer is whether the store could
      def purge_entries(_namespace)
        false
      end

      # Writes several entries and says, per key, whether the store took it
      # (#write). Here one call per key; a backend that can send them in one
      # round trip overrides it (RailsCache). Every key is tried: one whose
      # write raises answers false, and the error is given to the block.
      #
      # @param entries [Hash{String => Object}]
      # @param ttl [Integer, nil] seconds, for every entry
      # @yieldparam error [StandardError] what a write raised
      # @return [Hash{String => Boolean}]
      def write_many(entries, ttl: nil, &on_error)
        entries.to_h { |key, value| [key, answer(on_error) { write(key, value, ttl: ttl) }] }
      end

      # Removes several keys and says, per key, whether it is certainly gone
      # (#expunge). Here one call per key; a backend that can send them in
      # one round trip overrides it (RailsCache). Every key is tried: one
      # whose removal raises answers false, and the error is given to the
      # block.
      #
      # @param keys [Array<String>]
      # @yieldparam error [StandardError] what a removal raised
      # @return [Hash{String => Boolean}]
      def expunge_many(keys, &on_error)
        keys.to_h { |key| [key, answer(on_error) { expunge(key) }] }
      end

      # Reads several keys from the store itself (#read_fresh) and answers,
      # per key, the entry or nil. Here one read per key; a backend that can
      # fetch them in one round trip overrides it (RailsCache). A key whose
      # read raises answers nil.
      #
      # @param keys [Array<String>]
      # @return [Hash{String => Object, nil}]
      def read_many(keys)
        keys.to_h { |key| [key, fresh_or_nil(key)] }
      end

      # Removes several keys without asking whether they are gone (#delete):
      # for an invalidation that has failed already (its stamp was refused),
      # where a confirmation would be paid for twice. Here one call per key;
      # RailsCache sends them in one round trip where it can. Every key is
      # tried; an error is given to the block.
      #
      # @param keys [Array<String>]
      # @yieldparam error [StandardError] what a removal raised
      # @return [void]
      def delete_many(keys, &on_error)
        keys.each { |key| answer(on_error) { delete(key) } }
        nil
      end

      private

      def fresh_or_nil(key)
        read_fresh(key)
      rescue StandardError
        nil
      end

      # The store's answer as true or false; false, after the error is
      # handed on, when the call raised.
      def answer(on_error)
        yield ? true : false
      rescue StandardError => e
        on_error&.call(e)
        false
      end

      def prefixed_key(key)
        "#{prefix}:#{key}"
      end

      # Stores hand back string keys (JSON) or the hash as written; the
      # permission hash is read with symbol keys.
      def deep_symbolize(obj)
        case obj
        when Hash
          obj.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array
          obj.map { |v| deep_symbolize(v) }
        else
          obj
        end
      end
    end
  end
end
