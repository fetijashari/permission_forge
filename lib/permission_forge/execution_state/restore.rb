# frozen_string_literal: true

module PermissionForge
  module ExecutionState
    # What .set_until_restored hands back: puts back what the slot held when
    # it was set — once, and only where it was set (ExecutionState.owner: the
    # fiber of a :fiber slot, the execution context of an :execution slot).
    # Called from anywhere else (a Rack server finishing the response on
    # another thread) it does nothing there, and the slot stays set where it
    # was.
    #
    # @api private
    class Restore
      # @param name [Symbol] a key of KEYS
      # @param previous [Object, nil] what the slot held
      def initialize(name, previous)
        @name = name
        @previous = previous
        @owner = ExecutionState.owner(name)
        @done = false
      end

      # Takes and ignores the arguments a `rack.response_finished` callback
      # is given.
      #
      # @return [Boolean] whether it put the value back (false: done
      #   already, or called elsewhere)
      def call(*)
        return false if @done || !ExecutionState.owner(@name).equal?(@owner)

        @done = true
        ExecutionState.put_back(@name, @previous)
        true
      end
    end

    class << self
      # Sets the slot past the end of the current block: for a value that
      # must outlive the call that sets it (a Rack middleware keeps it until
      # the response is finished, after its #call returned).
      #
      # @param name [Symbol] a key of KEYS
      # @return [Restore] puts back what the slot held
      def set_until_restored(name, value)
        restore = Restore.new(name, self[name])
        self[name] = value
        restore
      end

      # A read-only reader of one slot, for a hot path that asks the same slot
      # on every call without the lookup of #[] (WebRequest.active?): the
      # store is looked up once, here.
      #
      # @param name [Symbol] a key of KEYS
      # @return [Proc] returns what the slot holds
      def reader(name)
        store = storage(name)
        -> { store[name] }
      end

      # Puts `previous` back in the slot (nil empties it), as .with does when
      # its block ends.
      #
      # @param name [Symbol] a key of KEYS
      # @param previous [Object, nil]
      # @return [void]
      def put_back(name, previous)
        store = storage(name)
        previous.nil? ? store.delete(name) : store[name] = previous
        nil
      end
    end
  end
end
