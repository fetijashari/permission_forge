module PermissionForge
  module Cache
    # A backend that stores nothing (config.cache_backend = :null): every read misses, so every
    # permission check rebuilds its hash. For tests and debugging.
    #
    # @api public
    class NullCache < Base
      def initialize(prefix: 'pf')
        super
      end

      # Nothing written is kept (see Base#keeps_entries?).
      def keeps_entries?
        false
      end

      # @return [nil] always a miss
      def read(_key)
        nil
      end

      # Nothing is kept, on purpose: that is not a failed write (false or nil
      # would say so — see Base#write).
      def write(_key, value, **)
        value
      end

      # @return [nil] there is nothing to remove
      def delete(_key)
        nil
      end

      # @return [nil] there is nothing to remove
      def clear
        nil
      end

      # Nothing is kept: nothing is left either.
      # rubocop:disable-next Naming/PredicateMethod -- removes the entries; the answer is whether the store could
      def clear_entries(_namespace)
        true
      end
    end
  end
end
