module PermissionForge
  # Group membership. Organisational only: it never gives Permission Sets.
  # Adding and removing go through the model callbacks (group_membership.*
  # audit events) after config.admin_assignment_authorization.
  #
  # @api private
  class PermissionSetGroupUsersController < ApplicationController
    include PermissionForge::AssignmentAuthorization

    before_action :set_group
    before_action :reject_locked

    def create
      user = member_user
      return redirect_to(group_path, alert: t('permission_forge.flash.permission_set_group_users.user_not_found')) unless user
      return if pf_assignment_refused?(@group, user.id, :add_member, group_path)

      membership = PermissionForge::PermissionSetGroupUser.new(permission_set_group: @group, user: user)
      return redirect_to(group_path, alert: t('permission_forge.flash.permission_set_group_users.add_failed')) unless membership.save

      redirect_to group_path, notice: t('permission_forge.flash.groups.member_added', name: person_name(user))
    end

    # The member must be somebody config.user_list_resolver lists (404 otherwise).
    def destroy
      membership = @group.permission_set_group_users.find(params[:id])
      PermissionForge::Admin::PeopleDirectory.new.find(membership.user_id) || pf_not_found
      return if pf_assignment_refused?(@group, membership.user_id, :remove_member, group_path)

      membership.destroy!
      redirect_to group_path, notice: t('permission_forge.flash.permission_set_group_users.removed')
    end

    private

    def set_group
      @group = PermissionForge::PermissionSetGroup.find(params[:group_id])
    end

    # A locked group's members are frozen.
    def reject_locked
      pf_reject_locked!(@group, group_path)
    end

    def member_user
      PermissionForge::Admin::PeopleDirectory.new.find(params[:user_id])
    end

    def person_name(user)
      PermissionForge::Admin::PersonLabel.new(user).name
    end

    def group_path
      permission_forge.group_path(@group)
    end
  end
end
