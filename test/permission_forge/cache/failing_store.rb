# frozen_string_literal: true

module PermissionForge
  module Cache
    # A cache store that fails on demand the way Redis, Memcached and Solid
    # Cache stores do: without raising. A failed read answers nil, a failed
    # write or delete answers false and changes nothing. `fail_when` decides,
    # per operation and key; `raise_instead` makes the failure an exception (a
    # store without a failsafe).
    #
    # `apply_next_failed_write` makes the next failed write take effect all
    # the same: the server applied it and the answer was lost. `refuse` turns
    # away values (it is given the value): a store with a size limit.
    class FailingStore < ActiveSupport::Cache::MemoryStore
      attr_accessor :fail_when, :raise_instead, :apply_next_failed_write, :refuse
      attr_reader :operations

      def initialize(*)
        super
        @operations = []
        @fail_when = ->(_operation, _key) { false }
      end

      def read(name, options = nil)
        failing?(:read, name) ? nil : super
      end

      def write(name, value, options = nil)
        failed = failing?(:write, name)
        return false if refuse&.call(value)
        return super unless failed

        super if apply_next_failed_write
        self.apply_next_failed_write = false
      end

      def delete(name, options = nil)
        failing?(:delete, name) ? false : super
      end

      # Everything fails, as when the server is gone.
      def down!
        self.fail_when = ->(_operation, _key) { true }
      end

      def up!
        self.fail_when = ->(_operation, _key) { false }
      end

      private

      def failing?(operation, name)
        key = name.to_s.delete_prefix('pf:')
        @operations << [operation, key]
        return false unless fail_when.call(operation, key)
        raise 'the cache server is gone' if raise_instead

        true
      end
    end
  end
end
