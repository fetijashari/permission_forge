# frozen_string_literal: true

module PermissionForge
  module Audit
    # Helpers for the runtime decision event tests.
    module RuntimeSupport
      # The payloads of `event` published inside the block.
      def published(event)
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe("#{event}.permission_forge") { |*, payload| seen << payload }
        yield
        seen
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # [result of the block, payloads of every runtime event published inside it]
      def published_runtime
        seen = []
        subscriber = ActiveSupport::Notifications.subscribe(/\.permission_forge\z/) do |name, *, payload|
          seen << payload.merge(name: name.delete_suffix('.permission_forge')) if payload[:category] == 'access'
        end
        result = yield
        [result, seen]
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      def store_runtime(*groups)
        PermissionForge.configuration.audit_runtime_events = groups
      end

      # A new request: what was published once is forgotten.
      def next_request!
        Runtime.reset!
      end

      def with_config(option, value)
        config = PermissionForge.configuration
        previous = config.public_send(option)
        config.public_send(:"#{option}=", value)
        yield
      ensure
        config.public_send(:"#{option}=", previous)
      end
    end
  end
end
