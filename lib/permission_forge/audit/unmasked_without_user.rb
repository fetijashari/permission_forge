# frozen_string_literal: true

require 'concurrent/map'

module PermissionForge
  module Audit
    # What makes a guarded attribute returned as stored inside a web request
    # with nobody signed in visible (masked_attributes_nil_user_strategy
    # :bypass; Configuration#masked_attributes_without_user_for answers
    # :record): exactly the reads :hide_in_requests would hide — every
    # guarded attribute of a masked model but its primary key and the raw
    # paths, never the user model. The attribute guard (AttributeAccessGuard)
    # calls .note for each such read.
    #
    # - The runtime event field.unmasked_without_user (group :bypass): the
    #   model, the attribute and the request (method, path, endpoint; request
    #   id and IP as event columns when the audit context has none), once per
    #   request per model and attribute (Runtime.once?). Nothing is built
    #   while nobody listens and the group is not stored (Audit::Gate): the
    #   read then costs one Gate check.
    # - One SECURITY warning per model and process in the log (Warnings.emit),
    #   so an app that stores no runtime event sees the gap too. At most
    #   WARNED_LIMIT models are remembered.
    #
    # Neither ever raises into the read.
    #
    # @api private
    module UnmaskedWithoutUser
      EVENT = 'field.unmasked_without_user'
      GATE = Gate.for(EVENT)

      # Models warned about in this process (by class, or by Resource name).
      WARNED = Concurrent::Map.new
      WARNED_LIMIT = 1_000

      class << self
        # @param model [Class, String, Symbol] the record's class (or the
        #   Resource name when no class is known)
        # @param attribute [Symbol, String]
        # @return [void]
        def note(model, attribute)
          warn_once(model, attribute) unless WARNED.key?(model)
          publish(model, attribute) if GATE.open? && Audit.instrument?(EVENT)
          nil
        end

        # Forgets which models were warned about (tests; Audit.reset!).
        # @return [void]
        def reset!
          WARNED.clear
        end

        private

        def publish(model, attribute)
          name = Runtime.model_name(model)
          attribute = attribute.to_s
          return unless Runtime.once?(EVENT, name, attribute, nil)

          with_request_context do
            Audit.instrument(EVENT) do
              { record_type: Runtime.record_type(model), record_id: nil, subject_user_id: nil,
                data: { 'model' => name, 'attribute' => attribute }.merge(WebRequest.details) }
            end
          end
        end

        # The request id and IP of the web request, for an event recorded
        # outside the admin's and the API's own audit context.
        def with_request_context(&)
          env = WebRequest.env
          return yield if Context[:request_id] || env.nil?

          request = ActionDispatch::Request.new(env)
          Context.with(request_id: cut(request.request_id), ip: cut(RequestContext.remote_ip(request).first), &)
        end

        def cut(value)
          value.presence && value.to_s[0, WebRequest::VALUE_LIMIT]
        end

        def warn_once(model, attribute)
          return if WARNED.size >= WARNED_LIMIT
          return unless WARNED.put_if_absent(model, true).nil?

          Warnings.emit("masked_attributes.unmasked_without_user.#{Runtime.model_name(model)}",
                        warning(model, attribute), severity: :security)
        rescue StandardError
          nil
        end

        def warning(model, attribute)
          request = WebRequest.details.values_at('method', 'path', 'endpoint').compact.join(' ')
          "#{Runtime.model_name(model)}##{attribute} was read in a web request with nobody signed in " \
            "(#{request.presence || 'a request'}) and returned as stored: masked_attributes_nil_user_strategy is " \
            ':bypass. Set it to :hide_in_requests to hide guarded attributes in web requests with nobody signed in ' \
            '(jobs, rake and the console keep the stored values), or sign the request in before it reads masked ' \
            'models. Logged once per model and process; the field.unmasked_without_user audit event (runtime ' \
            'group :bypass) records each request.'
        end
      end
    end
  end
end
