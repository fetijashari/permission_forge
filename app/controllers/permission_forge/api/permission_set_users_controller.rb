# frozen_string_literal: true

module PermissionForge
  module Api
    # Assignments of one Permission Set. Every grant and revocation runs
    # through the model callbacks (assignment.* audit events), after
    # api_assignment_authorization and then config.admin_assignment_authorization.
    class PermissionSetUsersController < BaseController
      include PermissionForge::AssignmentAuthorization

      # bulk_action → AssignmentAuthorization action; the keys are the
      # service's VALID_ACTIONS, anything else is a 422 before the service runs.
      BULK_ACTIONS = { 'assign' => :grant, 'revoke' => :revoke }.freeze

      before_action :set_permission_set

      def index
        scope = @permission_set.permission_set_users.includes(:user)
        render_collection(scope, serializer_for(:permission_set_user))
      end

      def create
        authorize_assignment!(@permission_set, [params[:user_id]])
        reject_widening!(:grant) unless performed?
        return if performed?

        user = find_host_user(params[:user_id])
        return if performed? || pf_assignment_refused_api?(@permission_set, user.id, :grant)

        create_assignment(user)
      end

      # The holder must be somebody config.user_list_resolver lists (404
      # otherwise). Revoking narrows access for a granting set, also a locked
      # one; on a locked Muting Permission Set it widens and is refused.
      def destroy
        psu = find_record(@permission_set.permission_set_users)
        return unless find_host_user(psu.user_id)

        authorize_assignment!(@permission_set, [psu.user_id])
        reject_widening!(:revoke) unless performed?
        return if performed? || pf_assignment_refused_api?(@permission_set, psu.user_id, :revoke)

        psu.destroy!
        head :no_content
      end

      def bulk
        authorize_assignment!(@permission_set, params[:user_ids])
        # On a locked set only what narrows access passes (an unknown
        # bulk_action is judged as a grant, then refused as a 422).
        reject_widening!(BULK_ACTIONS.fetch(params[:bulk_action].to_s, :grant)) unless performed?
        return if performed? || bulk_refused?

        render json: { data: bulk_assignment }, status: :ok
      rescue ArgumentError => e
        render json: { error: { status: 422, messages: e.message } }, status: :unprocessable_entity
      end

      private

      # 403 when the change would widen access on a locked set
      # (Admin::EditableLock.widening_lock: which way depends on is_muting).
      def reject_widening!(change)
        reject_locked!(pf_widening_lock(@permission_set, change))
      end

      def create_assignment(user)
        psu = @permission_set.permission_set_users.build(user: user, expires_at: pf_time_param(:expires_at))
        psu.save ? render_created(psu, serializer_for(:permission_set_user)) : render_validation_errors(psu)
      end

      # An unknown bulk_action raises ArgumentError (422, rescued in #bulk)
      # before anything is authorized or changed.
      def bulk_refused?
        action = BULK_ACTIONS.fetch(params[:bulk_action].to_s) do |name|
          PermissionForge::Services::BulkPermissionSetAssignment.validate_action!(name)
          raise ArgumentError, "Invalid action: #{name}" # a service action this controller does not map
        end
        pf_assignment_refused_api?(@permission_set, params[:user_ids], action)
      end

      def bulk_assignment
        PermissionForge::Services::BulkPermissionSetAssignment.call(
          permission_set: @permission_set,
          user_ids: bulk_user_ids,
          action: params[:bulk_action],
          created_by: PermissionForge.current_user,
          expires_at: pf_time_param(:expires_at)
        )
      end

      # The people of the request within config.user_list_resolver
      # (Admin::PeopleDirectory#find_all); an id naming nobody there is
      # skipped, as an unknown id always was.
      def bulk_user_ids
        PermissionForge::Admin::PeopleDirectory.new.find_all(params[:user_ids]).map(&:id)
      end

      def set_permission_set
        @permission_set = find_record(PermissionForge::PermissionSet, :permission_set_identifier)
      end
    end
  end
end
