# frozen_string_literal: true

module PermissionForge
  module Audit
    # The notification subscribers the engine installs once configuration is
    # final (Audit.install!). Each installer is a callable that receives the
    # configuration and returns the subscriber it installed, or nil when its
    # option is off:
    #
    #   Audit::Subscribers.register(:log, ->(config) {
    #     ActiveSupport::Notifications.subscribe(/\.permission_forge\z/) { |event| ... } if config.audit_log_subscriber
    #   })
    #
    # The log subscriber (config.audit_log_subscriber), the store subscriber
    # and the adapters for the legacy on_rule_bypass / on_field_filtered hooks
    # live in lib/permission_forge/audit/subscribers/ and register here.
    #
    # @api private
    module Subscribers
      @installers = {}
      @installed = {}

      class << self
        def register(name, installer)
          @installers[name.to_sym] = installer
        end

        # Idempotent: an installer whose subscriber is in place is not called again.
        def install!(configuration = PermissionForge.configuration)
          @installers.each do |name, installer|
            next if @installed.key?(name)

            subscriber = installer.call(configuration)
            @installed[name] = subscriber if subscriber
          end
        end

        def installed?(name)
          @installed.key?(name.to_sym)
        end

        def uninstall!(name)
          subscriber = @installed.delete(name.to_sym)
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
        end

        # Removes every installed subscriber (tests; a configuration change).
        def reset!
          uninstall!(@installed.keys.first) until @installed.empty?
        end

        def names
          @installers.keys
        end
      end
    end
  end
end
