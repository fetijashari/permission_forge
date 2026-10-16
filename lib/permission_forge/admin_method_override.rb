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
  # The JSON API's paths (`<mount>/api…`) are left alone: a JSON client says
  # the verb it means, and neither a `_method` field nor an
  # `X-HTTP-Method-Override` header turns its POST into another verb.
  #
  # @api private
  class AdminMethodOverride < Rack::MethodOverride
    # The engine's JSON API, below the mount point (PATH_INFO inside the engine).
    API_PATH = %r{\A/api(?:/|\.|\z)}

    def call(env)
      return @app.call(env) if API_PATH.match?(env[Rack::PATH_INFO].to_s)

      super
    end
  end
end
