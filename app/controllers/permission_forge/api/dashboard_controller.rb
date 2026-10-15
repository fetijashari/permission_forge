# frozen_string_literal: true

module PermissionForge
  module Api
    class DashboardController < BaseController
      before_action :authorize_stats!, only: :show

      def show
        render json: {
          data: {
            permission_sets_count: PermissionForge::PermissionSet.count,
            active_sets_count: PermissionForge::PermissionSet.active.count,
            resources_count: PermissionForge::Resource.count,
            rules_count: PermissionForge::PermissionSetRule.count,
            groups_count: PermissionForge::PermissionSetGroup.count,
            users_count: PermissionForge::PermissionSetUser.select(:user_id).distinct.count
          }
        }, status: :ok
      end

      private

      # While config.api_stats_require_admin is on (the default), only a
      # caller config.api_stats_authorization allows reads the stats; a
      # refusal is a 403 recorded as api.auth_failed (stats_not_authorized).
      # Without the lambda the 403 names it, as for the other lambdas.
      def authorize_stats!
        configuration = PermissionForge.configuration
        return unless configuration.api_stats_require_admin

        authorizer = configuration.api_stats_authorization
        return if authorizer ? authorizer.call(self) : legacy_admin_flag?

        pf_audit_refused('api.auth_failed', data: { 'reason' => 'stats_not_authorized',
                                                    'hook' => authorizer ? 'api_stats_authorization' : 'api_stats_require_admin' })
        render_not_authorized(authorizer ? nil : I18n.t('permission_forge.api.errors.stats_authorization_missing'))
      end

      # Through 0.15 the stats endpoint read an @admin = true that api_auth
      # set on the controller (documented in 0.14). Still honoured when
      # api_stats_authorization is not set, with a deprecation warning;
      # removed in 0.16.
      def legacy_admin_flag?
        return false unless @admin

        PermissionForge::Deprecation.warn(
          'Setting @admin on the API controller (in api_auth) to allow GET /api/stats is deprecated; ' \
          'set config.api_stats_authorization = ->(controller) { ... } instead',
          key: :api_stats_admin_ivar
        )
        true
      end
    end
  end
end
