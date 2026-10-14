# frozen_string_literal: true

module PermissionForge
  module Audit
    # The per-request (per-thread, or per-fiber under Rails' fiber isolation:
    # ExecutionState) store of what every event recorded inside a block
    # carries: the actor, the source, the request id and IP, a reason, and a
    # correlation id.
    #
    #   Audit::Context.with(source: 'admin_ui', request_id: request.request_id, ip: request.remote_ip) do
    #     ...
    #   end
    #
    # Blocks nest: an inner value overrides the outer one for the block, a
    # nil leaves the outer one in place, and the outer context is restored
    # when the block ends — also when it raises. Nothing is ever set outside
    # a block, so nothing can leak to the next request; as a second line of
    # defence the end of every executor run empties a context that was empty
    # when the run started (ExecutionState::RunHook): a request or a job ends
    # with none, and a block that wraps the run keeps its own
    # (with_audit_actor around an inline job keeps its actor after the job).
    #
    # @api public
    module Context
      KEY = :pf_audit_context
      TRANSACTION_KEY = :pf_audit_transaction_correlation
      SLOTS = %i[actor source request_id ip reason correlation_id].freeze
      EMPTY = {}.freeze

      class << self
        # @return [Hash] frozen; empty when nothing is set
        def current
          state[KEY] || EMPTY
        end

        # @param slot [Symbol] one of SLOTS
        # @return [Object, nil] the value of that slot in the current context
        def [](slot)
          current[slot]
        end

        # @param slots [Hash] actor: (an Actor, a user or a Hash), source:,
        #   request_id:, ip:, reason:, correlation_id:
        # @return the value of the block
        # @raise [ArgumentError] for an unknown slot, actor type or source
        def with(**slots, &)
          ExecutionState.with(KEY, current.merge(normalize(slots)).freeze, &)
        end

        # Empties the context of this thread (tests, the end of a request).
        def reset!
          state.delete(KEY)
          state.delete(TRANSACTION_KEY)
        end

        # One id per outermost open transaction (OpenTransaction), minted the
        # first time an event asks for it inside that transaction: a cascade
        # delete or a Review-and-save then shares one id.
        #
        # @return [String, nil] nil when no transaction is open
        def transaction_correlation_id
          transaction = OpenTransaction.current
          return unless transaction

          handle, id = state[TRANSACTION_KEY]
          return id if handle && !handle.finished?

          id = Audit.new_id
          state[TRANSACTION_KEY] = [transaction, id]
          id
        end

        private

        def state
          ExecutionState
        end

        def normalize(slots)
          slots.each_with_object({}) do |(slot, value), out|
            raise ArgumentError, "unknown audit context slot #{slot.inspect} (slots: #{SLOTS.join(', ')})" unless SLOTS.include?(slot)
            next if value.nil?

            out[slot] = cast(slot, value)
          end
        end

        def cast(slot, value)
          case slot
          when :actor then Actor.coerce(value)
          when :source then Source.validate!(value)
          else value.to_s
          end
        end
      end
    end
  end
end
