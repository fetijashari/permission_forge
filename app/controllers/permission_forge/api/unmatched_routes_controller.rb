# frozen_string_literal: true

module PermissionForge
  module Api
    # Any path and method under the API mount that no endpoint answers
    # (`GET /api/unknown`, `POST /api/audit_events`): a 404 in the API's JSON
    # envelope instead of Rails' HTML page. Drawn after every API route, and
    # only under /api. It runs the API's guards first: while api_enabled is
    # off it is the same bodiless 404 as every API route; a caller api_auth
    # refuses gets the 401 and a request with no tenant the 403, each
    # recorded as api.auth_failed like on any endpoint.
    #
    # @api private
    class UnmatchedRoutesController < BaseController
      def show
        render_not_found(I18n.t('permission_forge.api.errors.route_not_found'))
      end
    end
  end
end
