# frozen_string_literal: true

require 'rack/method_override'

module PermissionForge
  # Rack::MethodOverride for the admin screens, in the engine's own
  # middleware stack (PermissionForge::Engine: it runs only for requests the
  # host's router hands to the mounted engine). The admin's edit and delete
  # forms POST with a hidden `_method` (patch, delete), which this turns into
  # the verb the route wants. A full-stack host already has
  # Rack::MethodOverride, and a second pass is a no-op (it only rewrites a
  # POST); an API-only host (`rails new --api`) has none, and every such form
  # answered 404 — the engine brings its own, so the host adds nothing for it
  # (docs/admin-ui.md#api-only-applications names the three session
  # middlewares only).
  #
  # The JSON API's paths (`<mount>/api…`) are left alone by this override:
  # a JSON client says the verb it means. In a full-stack host the
  # application's own Rack::MethodOverride runs before the router for every
  # path, the API's included, as Rails has it (a `_method` field or an
  # `X-HTTP-Method-Override` header on a POST then changes its verb there);
  # api_auth and the API's guards apply either way.
  #
  # It keeps the app it wraps under its own name: Rack::MethodOverride's
  # instance variable is not part of Rack's API.
  #
  # @api private
  class AdminMethodOverride < Rack::MethodOverride
    # The engine's JSON API, below the mount point (PATH_INFO inside the engine).
    API_PATH = %r{\A/api(?:/|\.|\z)}

    # @param app [#call] the engine's next middleware
    def initialize(app)
      super
      @pf_app = app
    end

    def call(env)
      return @pf_app.call(env) if API_PATH.match?(env[Rack::PATH_INFO].to_s)

      super
    end
  end
end
