# frozen_string_literal: true

module PermissionForge
  module Audit
    module Subscribers
      # A notification subscriber of the gem, switched by an option of the
      # configuration: installed once (Audit.install!), silenced while the
      # option is off. ActiveSupport asks #silenced? before it delivers, so a
      # silenced subscriber costs nothing, and the option can change at run
      # time. The option's writer calls Gate.changed!, which is how Audit::Gate
      # knows the answer without asking every time.
      #
      # Subclasses name what they subscribe to (#pattern), when they are
      # silenced, and what they do with an event's payload (#deliver).
      class Base
        # @return [String, Regexp] the notification(s) to subscribe to
        def pattern
          raise NotImplementedError
        end

        # @param _name [String] the notification
        # @return [Boolean]
        def silenced?(_name)
          raise NotImplementedError
        end

        # Whether it can be handed the light payload ({ data:, objects: }) in
        # place of a built event (Audit::Gate#direct_listeners).
        def light? = false

        # The light payload, from Audit.instrument (the hook path that builds
        # no event).
        def deliver_light(name, payload)
          deliver(name, payload)
        end

        # @return [Object] the ActiveSupport subscriber, for Subscribers.uninstall!
        def subscribe!
          ActiveSupport::Notifications.subscribe(pattern, self)
        end

        # ActiveSupport's timed subscriber interface.
        def call(name, _started, _finished, _id, payload)
          deliver(name, payload)
        end

        private

        # @param name [String] "<event>.permission_forge"
        # @param payload [Hash] see Audit::Recorder#notification_payload
        def deliver(name, payload)
          raise NotImplementedError
        end

        def configuration
          PermissionForge.configuration
        end

        # A hook that raises follows config.audit_hook_failure_strategy: it
        # never breaks the request unless the strategy is :raise.
        def guarded(event, hook)
          yield
        rescue StandardError => e
          Failure.handle(e, strategy: configuration.audit_hook_failure_strategy, operation: :hook, event: event, hook: hook)
        end
      end
    end
  end
end
