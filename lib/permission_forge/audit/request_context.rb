# frozen_string_literal: true

module PermissionForge
  module Audit
    # The audit context of one admin UI or API request, set by the
    # around-action of both base controllers:
    #
    #   around_action :pf_audit_request
    #   def pf_audit_request(&) = PermissionForge::Audit::RequestContext.wrap(self, source: 'admin_ui', &)
    #
    # Inside the block every event carries the actor (Audit::ActorResolver),
    # the source, the request id and IP (config.audit_request_context, else
    # `request.request_id` and `request.remote_ip`) and, for a request that
    # can change something (anything but GET and HEAD), the `reason`
    # parameter and one correlation id for all its events. A read-only page
    # in Audit::AuditedViews is recorded after a successful response.
    #
    # Nothing is set outside the block, and the block restores the previous
    # context also when the action raises.
    #
    # @api private
    class RequestContext
      # The reason column is a varchar(255) (MySQL counts characters).
      REASON_LIMIT = 255
      REQUEST_VALUE_LIMIT = 255
      READ_ONLY_METHODS = %w[GET HEAD].freeze

      class << self
        # @param controller [ActionController::Metal]
        # @param source [String] 'admin_ui' or 'api'
        # @return the value of the block
        def wrap(controller, source:, &)
          new(controller, source).wrap(&)
        end

        # The request id and IP to store: config.audit_request_context
        # (lambda(controller) → { request_id:, ip: }; a key it returns — also
        # as nil — replaces the default) over request.request_id and the
        # remote IP (#remote_ip). A lambda that raises is reported and the
        # defaults are used.
        #
        # @return [Hash] { request_id:, ip: }
        def request_slots(controller, configuration: PermissionForge.configuration)
          request = controller.request
          slots = { request_id: request.request_id, ip: remote_ip(request).first }
          slots.merge!(custom_request_slots(controller, configuration))
          slots.transform_values { |value| value.presence && value.to_s[0, REQUEST_VALUE_LIMIT] }
        end

        # `request.remote_ip`, which raises IpSpoofAttackError when the
        # Client-IP and X-Forwarded-For headers disagree. That must neither
        # fail the request nor keep a refused sign-in out of the log: the
        # peer address is used instead, and the second value says so.
        #
        # @return [Array(String, Boolean)] [ip, spoofing suspected?]
        def remote_ip(request)
          [request.remote_ip, false]
        rescue ActionDispatch::RemoteIp::IpSpoofAttackError
          [request.remote_addr, true]
        end

        # The `reason` parameter (form field or JSON body key) of a request
        # that can change something: a String cleaned as an event column is
        # (one line, no NUL or other control character — PostgreSQL refuses a
        # NUL, and the assignment rows keep the reason too), stripped, nil
        # when blank, capped at REASON_LIMIT characters.
        #
        # @return [String, nil]
        def reason(controller)
          return unless mutating?(controller.request)

          value = controller.params[:reason]
          ColumnValues.value(value.strip)[0, REASON_LIMIT].strip.presence if value.is_a?(String)
        end

        def mutating?(request)
          !READ_ONLY_METHODS.include?(request.request_method)
        end

        # Records a refusal — a failed sign-in, a denied authorization, a
        # locked record — through Audit::Detached, so that a transaction the
        # caller rolls back does not take it along. Works before the request's
        # context is set (authentication runs first): source, request id and
        # IP are set for the event, and the actor is `actor:`, else the
        # request's, else whoever the host names (ActorResolver, no fallback:
        # an unidentified client stays unknown). `data` gets the request's
        # method, path and endpoint, and 'ip_spoof_suspected' => true when
        # the forwarding headers contradict each other (#remote_ip).
        #
        # @param event [String] e.g. 'admin.auth_failed', 'api.auth_failed', 'admin.lock_refused'
        # @param payload [Hash] see Audit::Recorder
        # @return [AuditEvent, nil]
        def refused(controller, event, source:, actor: nil, **payload)
          data = request_data(controller).merge(payload.delete(:data) || {})
          data['ip_spoof_suspected'] = true if remote_ip(controller.request).last
          Context.with(source: source, **request_slots(controller)) do
            actor ||= Context[:actor] || ActorResolver.call(controller, source: source, fallback: false)
            Detached.record(event, actor: actor, source: source, data: data, **payload)
          end
        end

        # @return [Hash] 'method', 'path' and 'endpoint' ("controller_path#action")
        def request_data(controller)
          request = controller.request
          { 'method' => request.request_method, 'path' => request.path,
            'endpoint' => "#{controller.controller_path}##{controller.action_name}" }
        end

        private

        def custom_request_slots(controller, configuration)
          custom = configuration.audit_request_context
          return {} unless custom

          answer = custom.call(controller)
          answer.respond_to?(:to_h) ? answer.to_h.symbolize_keys.slice(:request_id, :ip) : {}
        rescue StandardError => e
          Failure.handle(e, strategy: configuration.audit_hook_failure_strategy, operation: :request_context)
          {}
        end
      end

      def initialize(controller, source)
        @controller = controller
        @source = source
      end

      # @return the value of the block
      def wrap(&block)
        Context.with(**slots) do
          result = self.class.mutating?(@controller.request) ? Audit.correlate(&block) : block.call
          AuditedViews.record(@controller)
          result
        end
      end

      private

      # An actor or source the host has already named around the request
      # (PermissionForge.with_audit_actor in its own around-action) wins, as
      # an explicit block does everywhere else.
      def slots
        {
          actor: Context[:actor] || ActorResolver.call(@controller, source: @source),
          source: Context[:source] || @source,
          reason: self.class.reason(@controller),
          **self.class.request_slots(@controller)
        }
      end
    end
  end
end
