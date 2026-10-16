module PermissionForge
  # Bulk assign (paste emails/names and/or pick people) and bulk revoke for
  # one Permission Set. Both apply immediately, through the model callbacks
  # (one audit event per person, one correlation id per action), after
  # config.admin_assignment_authorization (AssignmentAuthorization).
  #
  # @api private
  class BulkAssignmentsController < ApplicationController
    include PermissionForge::AssignmentAuthorization
    include PermissionForge::ActingAdmin
    include PermissionForge::CacheConfirmation

    before_action :set_permission_set
    # A locked set refuses what widens access (EditableLock.widening_lock):
    # new holders of a granting set, removing holders of a Muting one.
    before_action :widening_grant_refused?, only: %i[new preview create]
    before_action :widening_revoke_refused?, only: %i[confirm_revoke revoke]

    def new
      load_form
    end

    # Shows who would be assigned, who already has it and what wasn't found.
    def preview
      load_form
      @result = matcher_result
      render :new
    end

    def create
      load_form
      @result = matcher_result
      @expiry_error = pf_resolve_expiry
      @nobody = @result.to_assign.empty?
      return render(:new, status: :unprocessable_entity) if @expiry_error || @nobody
      return if grant_refused?

      result = assign(@result.to_assign)
      # the service's one cache outcome: what the store confirmed, and its scope (CacheConfirmation)
      redirect_to assignments_path,
                  **cache_flash(result[:cache], { notice: :assigned, alert: :assigned_cache_kept },
                                count: result[:assigned], set: @permission_set.name)
    end

    def confirm_revoke
      @people = selected_people
    end

    def revoke
      ids = selected_people.map(&:id)
      return if pf_assignment_refused?(@permission_set, ids, :revoke, assignments_path)

      result = PermissionForge::Services::BulkPermissionSetAssignment.call(
        permission_set: @permission_set, user_ids: ids, action: :revoke
      )
      redirect_to assignments_path,
                  **cache_flash(result[:cache], { notice: :revoked, alert: :revoked_cache_kept },
                                count: result[:revoked], set: @permission_set.name)
    end

    private

    def set_permission_set
      @permission_set = PermissionForge::PermissionSet.find(params[:permission_set_id])
    end

    def grant_refused?
      pf_assignment_refused?(@permission_set, @result.to_assign.map(&:id), :grant, assignments_path)
    end

    def assignments_path
      permission_forge.permission_set_path(@permission_set, tab: 'assignments')
    end

    def widening_grant_refused?
      pf_widening_refused?(pf_widening_lock(@permission_set, :grant), permission_forge.permission_set_path(@permission_set))
    end

    def widening_revoke_refused?
      pf_widening_refused?(pf_widening_lock(@permission_set, :revoke), assignments_path)
    end

    def load_form
      @text = params[:identifiers].to_s
      @query = params[:q].to_s.strip
      @picked_ids = Array(params[:user_ids]).compact_blank.map(&:to_s)
      @people = people_directory.pick(query: @query, limit: 8)
      pf_load_expiry
    end

    def assign(people)
      PermissionForge::Services::BulkPermissionSetAssignment.call(
        permission_set: @permission_set, user_ids: people.map(&:id), action: :assign,
        created_by: pf_acting_admin_record, expires_at: @expires_at
      )
    end

    def matcher_result
      PermissionForge::Admin::BulkPeopleMatcher.new(directory: people_directory)
                                               .call(text: @text, user_ids: @picked_ids, permission_set: @permission_set)
    end

    # One per request: the picker and the matcher share its resolved people.
    def people_directory
      @people_directory ||= PermissionForge::Admin::PeopleDirectory.new
    end

    def selected_people
      people_directory.find_all(params[:user_ids])
    end
  end
end
