# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options for the audit event log ({PermissionForge::Audit}): what is
    # recorded, who is recorded as the actor, what happens when a record
    # cannot be written, and how long events are kept.
    #
    # The older options stay as they are: `audit_trail_enabled` and
    # `audit_user_class` (created_by / updated_by on the live row),
    # `on_rule_bypass` and `on_field_filtered` (callbacks).
    #
    # @api public
    module AuditSettings
      AUDIT_EVENTS = [:auto, true, false].freeze
      CHANGE_FAILURE_STRATEGIES = %i[raise report log].freeze
      HOOK_FAILURE_STRATEGIES = %i[report log raise].freeze

      # The groups of runtime (access) events that can be stored, as named in
      # the event catalogue (Audit::EventCatalog):
      #   denied          — access.denied, action.denied
      #   bypass          — rule.bypassed, query.unscoped
      #   field_read      — field.access
      #   params_filtered — params.filtered, write.masked_skipped
      #   cache           — permissions.rebuilt, permissions.invalidated
      RUNTIME_GROUPS = %i[denied bypass field_read params_filtered cache].freeze

      # Whether audit events are stored in the audit_events table.
      #   :auto  (default) when the table exists; when it does not, a boot
      #          warning is logged, the security audit reports it, and changes
      #          still work — an upgrade is never broken by an unrun migration
      #   true   always (a missing table then fails every change under the
      #          default :raise strategy)
      #   false  never (events are still published as notifications)
      attr_reader :audit_events

      # Lambda(controller) returning who acts in an admin UI or API request: a
      # user, an Audit::Actor, or a Hash { type:, id:, label: }. nil (default)
      # falls back to current_user_resolver; under HTTP Basic auth the
      # supplied username is recorded with actor_type 'basic_auth'.
      #   # Rails 8's authentication generator, under HTTP Basic (its sign-in does not run there):
      #   config.audit_actor_resolver = ->(controller) { Session.find_by(id: controller.request.cookie_jar.signed[:session_id])&.user }
      attr_accessor :audit_actor_resolver

      # Lambda(controller) returning the request context stored with each
      # event: a Hash with :request_id and :ip. nil (default) records the
      # request id and the remote IP.
      attr_accessor :audit_request_context

      # What happens when a change event cannot be written (the table is
      # unreachable, say) — change events are written inside the transaction
      # of the change:
      #   :raise  (default) the change rolls back: no change without its record
      #   :report the change goes through; the error is logged and handed to
      #           Rails.error (handled)
      #   :log    the change goes through; the error is logged only
      attr_reader :audit_change_failure_strategy

      # What happens when a notification subscriber, a legacy hook, or the
      # store of a runtime event fails: :report (default), :log or :raise.
      attr_reader :audit_hook_failure_strategy

      # Which runtime event groups are stored (every runtime event is published
      # regardless). Default: %i[denied]. See RUNTIME_GROUPS.
      attr_reader :audit_runtime_events

      # When true, every audit event is also written to Rails.logger.
      attr_reader :audit_log_subscriber

      # How long events are kept: a duration (90.days), seconds, or nil
      # (default) to keep them forever. Only the purge service deletes events,
      # and only ones older than this.
      attr_reader :audit_retention_period

      # Lambda(controller) returning whether the request may read the audit
      # log (pages, exports, the API endpoint). nil (default): anyone with
      # admin access.
      attr_accessor :audit_log_authorization

      # Lambda(controller, target, user_ids, action) returning whether the
      # request may change who holds a Permission Set or belongs to a group:
      # target is the PermissionSet or PermissionSetGroup, user_ids the people
      # concerned (cast to the user key type), action one of :grant, :revoke,
      # :change_expiry, :review, :add_member, :remove_member. Asked by the HTML
      # admin and by the API assignment endpoints (after
      # api_assignment_authorization). A refusal changes nothing. nil
      # (default): no extra check. See PermissionForge::AssignmentAuthorization.
      attr_accessor :admin_assignment_authorization

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_audit_defaults
        @audit_events = :auto
        @audit_actor_resolver = nil
        @audit_request_context = nil
        @audit_change_failure_strategy = :raise
        @audit_hook_failure_strategy = :report
        @audit_runtime_events = %i[denied].freeze
        @audit_log_subscriber = false
        @audit_retention_period = nil
        @audit_log_authorization = nil
        @admin_assignment_authorization = nil
        # a new configuration may become PermissionForge.configuration
        audit_observation_changed!
      end

      # @raise [PermissionForge::ConfigurationError] for anything but :auto,
      #   true or false (a string from ENV would otherwise pass for :auto)
      def audit_events=(value)
        @audit_events = one_of!(:audit_events, value, AUDIT_EVENTS)
      end

      def audit_change_failure_strategy=(value)
        @audit_change_failure_strategy = one_of!(:audit_change_failure_strategy, value, CHANGE_FAILURE_STRATEGIES)
      end

      def audit_hook_failure_strategy=(value)
        @audit_hook_failure_strategy = one_of!(:audit_hook_failure_strategy, value, HOOK_FAILURE_STRATEGIES)
      end

      # Symbols or strings; nil means none.
      def audit_runtime_events=(value)
        groups = Array(value).map { |group| group.to_s.to_sym }
        unknown = groups - RUNTIME_GROUPS
        unless unknown.empty?
          raise PermissionForge::ConfigurationError,
                "audit_runtime_events: unknown group(s) #{unknown.map(&:inspect).join(', ')} " \
                "(known: #{RUNTIME_GROUPS.map(&:inspect).join(', ')})"
        end

        # frozen: a group pushed in place would pass Audit::Gate by
        @audit_runtime_events = groups.uniq.freeze
        audit_observation_changed!
      end

      def audit_log_subscriber=(value)
        @audit_log_subscriber = value
        audit_observation_changed!
      end

      # @param group [Symbol, nil] a runtime group of the catalogue
      # @return [Boolean] whether runtime events of that group are stored
      def store_runtime_group?(group)
        !group.nil? && audit_runtime_events.include?(group.to_sym)
      end

      # The one definition of a valid retention period (the setter and
      # Services::AuditEventPurger both ask it).
      #
      # @param value [ActiveSupport::Duration, Numeric, nil]
      # @return [ActiveSupport::Duration, nil] a Duration stays as given (calendar
      #   arithmetic), a number is seconds
      # @raise [PermissionForge::ConfigurationError] for anything else
      def self.retention_period(value)
        return if value.nil?

        period = value.is_a?(ActiveSupport::Duration) || !value.is_a?(Numeric) ? value : value.seconds
        return period if period.is_a?(ActiveSupport::Duration) && period.to_i.positive?

        raise PermissionForge::ConfigurationError,
              "audit_retention_period must be a positive duration (90.days), a number of seconds or nil (got #{value.inspect})"
      end

      def audit_retention_period=(value)
        AuditSettings.retention_period(value)
        @audit_retention_period = value
      end

      private

      # Audit::Gate keeps whether a runtime event is stored or heard.
      def audit_observation_changed!
        PermissionForge::Audit::Gate.changed! if defined?(PermissionForge::Audit::Gate)
      end

      def one_of!(option, value, allowed)
        return value if allowed.include?(value)

        raise PermissionForge::ConfigurationError,
              "#{option} must be one of #{allowed.map(&:inspect).join(', ')} (got #{value.inspect})"
      end
    end
  end
end
