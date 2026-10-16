module PermissionForge
  # Permission Set Groups: purely organisational. Membership never grants
  # access; changes here save immediately and never change anyone's access.
  #
  # @api private
  class PermissionSetGroupsController < ApplicationController
    include PermissionForge::CopyRefusal

    before_action :set_group, except: %i[index create]
    before_action :reject_locked, only: %i[update destroy confirm_destroy add_set remove_set]

    def index
      load_index
      @new_open = params[:new].present?
    end

    def create
      @group = PermissionForge::PermissionSetGroup.new(name: pf_text_param(:name), is_active: true, is_editable: true)
      return render_blank_name if @group.name.blank?

      @group.save!
      redirect_to permission_forge.group_path(@group), notice: t('permission_forge.flash.groups.created', name: pf_record_name(@group))
    end

    def show
      @sets = @group.permission_sets.order(:name)
      @other_sets = PermissionForge::PermissionSet.where.not(id: @sets.select(:id)).includes(:permission_set_group).order(:name)
      @members = @group.permission_set_group_users.includes(:user).order(:created_at)
      @candidates = PermissionForge.configuration.assignable_users(exclude_ids: @members.map(&:user_id))
      @people_counts = PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
    end

    def update
      attrs = group_params
      return redirect_to(permission_forge.group_path(@group), alert: t('permission_forge.errors.admin.group_blank')) if blank_name?(attrs)

      unless @group.update(attrs)
        return redirect_to(permission_forge.group_path(@group), alert: PermissionForge::Admin::ErrorSentence.first(@group.errors))
      end

      redirect_to permission_forge.group_path(@group), notice: t('permission_forge.flash.groups.updated')
    end

    def duplicate
      copy = PermissionForge::Services::PermissionSetGroupCloner.call(
        permission_set_group: @group, attrs: { name: t('permission_forge.permission_sets.copy_name', name: @group.name), is_editable: true },
        unlock: true
      )
      redirect_to permission_forge.group_path(copy), notice: t('permission_forge.flash.groups.duplicated', name: pf_record_name(@group))
    rescue ActiveRecord::RecordInvalid => e
      redirect_to permission_forge.group_path(@group), alert: pf_copy_refused_message(e, pf_record_name(@group))
    end

    def confirm_destroy; end

    def destroy
      name = pf_record_name(@group)
      @group.destroy!
      redirect_to permission_forge.groups_path, notice: t('permission_forge.flash.groups.deleted', name: name)
    end

    # Moving a set here also changes the list of the group it is in now: a
    # locked one keeps it (EditableLock.locked_group_for_move), as in the
    # set editor and the API.
    def add_set
      set = PermissionForge::PermissionSet.find(params[:permission_set_id])
      leaving = PermissionForge::Admin::EditableLock.locked_group_for_move(from: set.permission_set_group_id, to: @group.id)
      return if pf_reject_locked!([set, leaving], permission_forge.group_path(@group))

      set.update!(permission_set_group: @group)
      redirect_to permission_forge.group_path(@group), notice: t('permission_forge.flash.groups.set_added', set: pf_record_name(set))
    end

    def remove_set
      set = @group.permission_sets.find(params[:permission_set_id])
      return if pf_reject_locked!(set, permission_forge.group_path(@group))

      set.update!(permission_set_group: nil)
      redirect_to permission_forge.group_path(@group), notice: t('permission_forge.flash.groups.set_removed', set: pf_record_name(set))
    end

    private

    def set_group
      @group = PermissionForge::PermissionSetGroup.find(params[:id])
    end

    def load_index
      @groups = PermissionForge::PermissionSetGroup.includes(:permission_sets, :permission_set_group_users).order(:name)
      @ungrouped = PermissionForge::PermissionSet.where(permission_set_group_id: nil).order(:name)
    end

    # Re-renders the index with the "new group" form open and an error.
    def render_blank_name
      @new_error = t('permission_forge.errors.admin.group_blank')
      @new_open = true
      load_index
      render(:index, status: :unprocessable_entity)
    end

    def group_params
      attrs = pf_require_hash(:group).permit(:name, :description, :is_active).tap { |permitted| strip_name!(permitted) }
      pf_boolean_attributes(attrs, :is_active)
    end

    # A blank name over a generated one, or a blank description over none,
    # is no change (Admin::Prefill.posted).
    def strip_name!(attrs)
      attrs[:name] = PermissionForge::Admin::Prefill.posted(@group, :name, attrs[:name].to_s.strip) if attrs.key?(:name)
      attrs[:description] = PermissionForge::Admin::Prefill.posted(@group, :description, attrs[:description]) if attrs.key?(:description)
    end

    # A name was submitted but is empty.
    def blank_name?(attrs)
      attrs.key?(:name) && attrs[:name].blank?
    end

    def reject_locked
      pf_reject_locked!(@group, permission_forge.group_path(@group))
    end
  end
end
