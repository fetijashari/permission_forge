module PermissionForge
  # Special actions on a Resource (e.g. export, sync). Saves apply immediately.
  # With controller_action_discovery on, the drawers also show where an action
  # runs and what its row means; discovered actions added from the Actions tab
  # go through Admin::ChangeSet instead (review, then apply).
  #
  # @api private
  class ResourceActionsController < ApplicationController
    before_action :set_resource
    before_action :set_action, only: %i[show update destroy confirm_destroy]
    before_action :reject_locked, only: %i[new create update destroy confirm_destroy]

    # `?key=export` opens the form for a discovered controller action.
    def new
      @action_record = @resource.resource_actions.build(name: suggested_key, is_active: true,
                                                        is_permitted: !@permission_set.is_muting)
      load_rows
    end

    def create
      @action_record = @resource.resource_actions.build(action_params)
      normalize_name!(@action_record)
      @errors = validate(@action_record)
      return render_invalid if @errors.any?

      @action_record.save!
      redirect_to resource_path, notice: t('permission_forge.flash.actions.created', action: @action_record.display_name)
    end

    def show
      load_rows
      @across = @action_rows.across_sets(@action_record.name)
      @people_count = pf_people_count(@permission_set)
    end

    # A blank label over a generated one, or a blank over nothing, is no
    # change (Admin::Prefill.posted); an unchanged action is not saved, and
    # says so (SaveNotice).
    def update
      attrs = PermissionForge::Admin::Prefill.posted_attributes(@action_record, action_params.except(:name), :label, :description)
      pf_save_changed(@action_record, attrs, &:save!)
      redirect_to pf_back_or(resource_path),
                  **pf_save_flash(@action_record) { t('permission_forge.flash.actions.updated', action: @action_record.display_name) }
    end

    def confirm_destroy; end

    def destroy
      name = @action_record.display_name
      @action_record.destroy!
      redirect_to resource_path, notice: t('permission_forge.flash.actions.deleted', action: name)
    end

    private

    def set_resource
      @permission_set = PermissionForge::PermissionSet.find(params[:permission_set_id])
      @resource = @permission_set.resources.find_by!(name: params[:resource_model])
    end

    def set_action
      @action_record = @resource.resource_actions.find(params[:id])
    end

    # The action's chain (action, Resource, Permission Set), or the Resource's for a new action.
    def reject_locked
      pf_reject_locked!(@action_record || @resource, resource_path)
    end

    def resource_path
      permission_forge.permission_set_resource_path(@permission_set, @resource.name, tab: 'actions')
    end

    def action_params
      pf_boolean_attributes(pf_require_hash(:resource_action).permit(:name, :label, :description, :is_permitted, :is_active),
                            :is_permitted, :is_active)
    end

    # "Export CSV " => "export_csv"
    def normalize_name!(record)
      record.name = record.name.to_s.strip.downcase.tr(' ', '_')
    end

    # Rows for the drawers: endpoints, guard status and effect. @row is the
    # row of the action in the form (nil for a key discovery does not know).
    def load_rows
      @action_rows = PermissionForge::Admin::ActionRows.new(@resource)
      @row = @action_rows.row(@action_record.name)
    end

    def render_invalid
      load_rows
      render :new, status: :unprocessable_entity
    end

    def suggested_key
      key = params[:key].to_s
      key if key.match?(PermissionForge::ControllerActions::KEY_FORMAT)
    end

    def validate(record)
      errors = {}
      if !record.name.to_s.match?(PermissionForge::ControllerActions::KEY_FORMAT)
        errors[:name] = t('permission_forge.errors.admin.action_format')
      elsif @resource.resource_actions.where(name: record.name).exists?
        errors[:name] = t('permission_forge.errors.admin.action_taken')
      end
      errors
    end
  end
end
