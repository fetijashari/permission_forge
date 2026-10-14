# frozen_string_literal: true

module PermissionForge
  module Cache
    # The errors a store rescued during a call and handed to its error
    # handler. Rails' Redis store rescues a Redis that cannot be reached,
    # hands the error to its handler (the `error_handler:` option) and goes
    # on as if nothing had been asked of it. Its answer to #write_multi is
    # then no proof: Rails 7.1 to 8.1 answer nil, the store Rails 8.2 ships
    # answers the same Hash whether the batch was written or not. The call
    # of the handler is the one sign every version gives, so
    # RailsCache#write_multi asks here whether there was one.
    #
    # The first time a store is watched, the handler it keeps (its
    # @error_handler) is wrapped: the wrapper notes the error for the call
    # being watched in this execution context, then calls the store's own
    # handler (if it has one) with the same arguments, as the store would
    # have. Outside a watched call it only hands the error on. A store
    # without an @error_handler is not watched (nothing is noted).
    #
    # @api private
    module HandledErrors
      # ExecutionState slot: the errors noted for the watched call in progress.
      KEY = :pf_store_errors
      LOCK = Mutex.new
      private_constant :LOCK

      class << self
        # Runs the block (a call of `store`) and returns its value with the
        # errors the store handed its error handler meanwhile, in this
        # execution context. An entry is nil when the handler was given no
        # exception: a call is still noted.
        #
        # @return [Array(Object, Array<Exception, nil>)]
        def during(store, &)
          return [yield, []] unless store.instance_variable_defined?(:@error_handler)

          wrap(store)
          handled = []
          [ExecutionState.with(KEY, handled, &), handled]
        end

        # Runs the block (a write to `store`) and says whether it was written:
        # the store answered truthy and handed its error handler no error
        # meanwhile (Rails 8.2's Redis store answers the same either way).
        # Also returns the last error handed on, if any.
        #
        # @return [Array(Boolean, Exception, nil)]
        def written(store, &)
          answer, handled = during(store, &)
          [answer ? handled.empty? : false, handled.compact.last]
        end

        private

        # Puts a Handler in front of the store's own error handler, once.
        def wrap(store)
          return if store.instance_variable_get(:@error_handler).is_a?(Handler)

          LOCK.synchronize do
            handler = store.instance_variable_get(:@error_handler)
            store.instance_variable_set(:@error_handler, Handler.new(handler)) unless handler.is_a?(Handler)
          end
        end
      end

      # Stands in for a store's error handler.
      class Handler
        def initialize(handler)
          @handler = handler
        end

        # Notes the error for the watched call (if one is in progress), then
        # hands everything to the store's own handler.
        def call(*, **details, &)
          ExecutionState[KEY]&.push(details[:exception])
          @handler&.call(*, **details, &)
        end
      end
    end
  end
end
