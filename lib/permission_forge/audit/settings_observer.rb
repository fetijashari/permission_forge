# frozen_string_literal: true

module PermissionForge
  module Audit
    # Records an `audit.settings_observed` event when the audit settings in
    # force differ from those of the most recent such event, so "was auditing
    # ever off, and since when" can be answered from the log. The engine calls
    # it at boot (not in the test environment); it never raises.
    #
    # Only the settings at boot are observed: a toggle made at runtime after
    # boot is not seen until the next boot or an explicit call.
    #
    # Lambdas are recorded as "set" / "unset" only, never their code.
    #
    #   PermissionForge::Audit::SettingsObserver.call  # => AuditEvent | nil
    #
    # @api private
    module SettingsObserver
      EVENT = 'audit.settings_observed'
      OPTIONS = %i[
        audit_events audit_actor_resolver audit_request_context audit_change_failure_strategy
        audit_hook_failure_strategy audit_runtime_events audit_log_subscriber audit_retention_period
        audit_log_authorization admin_assignment_authorization
      ].freeze

      class << self
        # @return [AuditEvent, nil] the new event; nil when nothing changed,
        #   the table is missing, auditing is off or recording failed
        def call(configuration: PermissionForge.configuration)
          return unless PermissionForge::AuditEvent.table_exists?

          settings = fingerprint(configuration)
          return if last_observed == settings

          payload = { data: { 'settings' => settings }, actor: { type: 'system', label: ActorCodes::BOOT }, source: 'service' }
          return PermissionForge::Audit.record(EVENT, **payload) unless configuration.audit_events == false

          # Auditing is off: Audit.record would store nothing, yet "was auditing
          # ever off" is what this event answers. Stored directly, not published.
          Recorder.new(EventCatalog.fetch(EVENT), payload).store!
        rescue StandardError => e
          Rails.logger&.warn("[PermissionForge] could not record the audit settings: #{e.class}: #{e.message}") if defined?(Rails)
          nil
        end

        # @return [Hash{String => Object}] stable, JSON-safe values
        def fingerprint(configuration = PermissionForge.configuration)
          OPTIONS.to_h { |option| [option.to_s, value_of(configuration.public_send(option))] }
        end

        private

        def value_of(value)
          case value
          when nil then 'unset'
          when Array then value.map(&:to_s).sort
          when ActiveSupport::Duration, Numeric then value.to_i
          when Symbol then value.to_s
          when String, true, false then value
          else 'set' # a lambda, or anything else: only that it is configured
          end
        end

        def last_observed
          PermissionForge::AuditEvent.unscoped.where(event: EVENT).order(occurred_at: :desc, id: :desc).first&.data&.[]('settings')
        end
      end
    end
  end
end
