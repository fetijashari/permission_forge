# frozen_string_literal: true

module PermissionForge
  module Audit
    # Who acts in an admin UI or API request — never taken from what the
    # client sends (parameters, headers), only from what the host and the
    # engine have verified:
    #
    #   1. config.audit_actor_resolver, called with the controller (a user, an
    #      Actor or a Hash { type:, id:, label: }; nil: it does not know)
    #   2. the signed-in host user (config.current_user_resolver)
    #   3. admin UI under HTTP Basic: the username that was checked, as
    #      actor_type 'basic_auth' with no id
    #
    # Nobody named: the request's fallback — unknown in the admin UI, an
    # anonymous API client in the API (api_auth said yes, but not who).
    #
    # A step that raises, or answers with something that is no actor, makes
    # the actor unknown and is reported (Audit::Failure, under
    # config.audit_hook_failure_strategy): the request goes on.
    #
    # @api private
    class ActorResolver
      # The request env key under which BasicAuthentication leaves the
      # username it has just verified. Not reachable from a header (those are
      # HTTP_*).
      BASIC_AUTH_ENV = 'permission_forge.audit.basic_auth_user'
      API_CLIENT_LABEL = 'API client'

      # The steps tried, in order, per request source; the first that names
      # someone wins.
      STEPS = {
        'admin_ui' => %i[configured_actor current_user basic_auth_user],
        'api' => %i[configured_actor current_user]
      }.freeze

      # Who acts when no step names anyone.
      FALLBACKS = {
        'admin_ui' => -> { Actor.unknown },
        'api' => -> { Actor.new(type: 'api', label: API_CLIENT_LABEL) }
      }.freeze

      # @param controller [ActionController::Metal]
      # @param source [String] 'admin_ui' or 'api'
      # @param fallback [Boolean] false: unknown instead of the source's
      #   fallback when nobody is named (a refused request)
      # @return [Actor] never nil
      def self.call(controller, source:, fallback: true, configuration: PermissionForge.configuration)
        new(controller, configuration).call(source, fallback: fallback)
      end

      def initialize(controller, configuration)
        @controller = controller
        @configuration = configuration
      end

      # @return [Actor]
      def call(source, fallback: true)
        identify(source) || (fallback ? FALLBACKS.fetch(source).call : Actor.unknown)
      rescue StandardError => e
        Failure.handle(e, strategy: @configuration.audit_hook_failure_strategy, operation: :actor, source: source)
        Actor.unknown
      end

      # Who the request names, without a fallback. Raises what a step raises.
      #
      # @return [Actor, nil]
      def identify(source)
        STEPS.fetch(source).each do |step|
          actor = send(step)
          return actor if actor
        end
        nil
      end

      private

      def configured_actor
        resolver = @configuration.audit_actor_resolver
        coerce(resolver.call(@controller)) if resolver
      end

      def current_user
        coerce(PermissionForge.current_user)
      end

      # Set by BasicAuthentication only after the credentials matched.
      def basic_auth_user
        username = @controller.request.env[BASIC_AUTH_ENV]
        Actor.new(type: 'basic_auth', label: username) if username.present?
      end

      # A user without an id names nobody; anything Actor.coerce cannot read
      # raises (and so counts as a failure).
      def coerce(value)
        actor = Actor.coerce(value)
        return if actor.nil? || (actor.type == 'user' && actor.id.nil?)

        actor
      end
    end
  end
end
