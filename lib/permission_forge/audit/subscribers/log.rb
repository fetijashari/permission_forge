# frozen_string_literal: true

module PermissionForge
  module Audit
    module Subscribers
      # config.audit_log_subscriber = true: one structured line per audit
      # event (stored or not) in Rails.logger, at info level —
      #
      #   [PermissionForge] audit {"event":"access.denied","category":"access","actor_type":"user","actor_id":"7",...}
      #
      # The line carries ids, never the name snapshots (actor_label,
      # record_label): logs usually travel further than the audit table.
      # Silenced while the option is off; notifications that are not audit
      # events (cache_failure.permission_forge) are left alone.
      class Log < Base
        SUFFIX = '.permission_forge'
        PREFIX = '[PermissionForge] audit '
        OMITTED = %i[actor_label record_label audit_event objects].freeze

        def pattern = /\.permission_forge\z/

        def silenced?(_name)
          !configuration.audit_log_subscriber
        end

        private

        def deliver(name, payload)
          return unless configuration.audit_log_subscriber && defined?(Rails) && Rails.logger

          event = name.delete_suffix(SUFFIX)
          return unless EventCatalog.registered?(event)

          guarded(event, :audit_log_subscriber) { Rails.logger.info(PREFIX + line(payload).to_json) }
        end

        def line(payload)
          payload.except(*OMITTED).compact
        end
      end

      register(:log, ->(_config) { Log.new.subscribe! })
    end
  end
end
