# frozen_string_literal: true

module PermissionForge
  module Api
    # Members of one Permission Set Group. Adding and removing run through
    # the model callbacks (group_membership.* audit events), after
    # api_assignment_authorization and then config.admin_assignment_authorization.
    class PermissionSetGroupUsersController < BaseController
      include PermissionForge::AssignmentAuthorization

      before_action :set_group

      def index
        scope = @group.permission_set_group_users.includes(:user)
        render_collection(scope, serializer_for(:permission_set_group_user))
      end

      # A user_id that is missing, not an id, or names nobody
      # config.user_list_resolver lists is a 422 keyed by user_id
      # (BaseController#requested_user), after the authorization hooks.
      def create
        user_id = params[:user_id]
        authorize_assignment!(@group, [user_id])
        enforce_editable!(@group) unless performed?
        return if performed?

        user = requested_user
        return if pf_assignment_refused_api?(@group, user.id, :add_member)

        gu = @group.permission_set_group_users.build(user: user)
        save_and_render(gu, :permission_set_group_user)
      end

      # The member must be somebody config.user_list_resolver lists (404 otherwise).
      def destroy
        gu = find_record(@group.permission_set_group_users)
        return unless find_host_user(gu.user_id)

        authorize_assignment!(@group, [gu.user_id])
        enforce_editable!(gu) unless performed?
        return if performed? || pf_assignment_refused_api?(@group, gu.user_id, :remove_member)

        gu.destroy!
        head :no_content
      end

      private

      def set_group
        @group = find_record(PermissionForge::PermissionSetGroup, :permission_set_group_identifier)
      end
    end
  end
end
