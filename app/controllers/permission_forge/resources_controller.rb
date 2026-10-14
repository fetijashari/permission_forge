module PermissionForge
  # A Resource inside a Permission Set: what people can do with one model
  # (CRUD, record scope), its fields, actions and record rules.
  #
  # @api private
  class ResourcesController < ApplicationController
    TABS = %w[fields actions rules].freeze
    GRANTING_PRESETS = %w[full read nothing].freeze
    MUTING_PRESETS = %w[hide_sensitive block_changes leave].freeze
    # Resource flags each preset starts with (others start off).
    PRESET_FLAGS = {
      'full' => { read_access: true, create_access: true, edit_access: true, delete_access: true },
      'read' => { read_access: true },
      'block_changes' => { create_access: true, edit_access: true, delete_access: true }
    }.freeze
    # Field level each preset gives the model's columns (nil = no fields).
    PRESET_LEVELS = { 'full' => 'edit', 'read' => 'read', 'nothing' => 'hidden', 'hide_sensitive' => 'hide_sensitive' }.freeze

    before_action :set_permission_set
    before_action :set_resource, except: %i[new create]
    before_action :reject_locked_set, only: %i[new create review apply sync destroy confirm_destroy]
    before_action :reject_locked_resource, only: %i[review apply sync destroy confirm_destroy]

    def new
      load_new_form
    end

    def create
      load_new_form
      model = @catalog.find(params[:model_name])
      @error = model_error(model)
      return render(:new, status: :unprocessable_entity) if @error

      resource = build_resource(model, @preset)
      redirect_to permission_forge.permission_set_resource_path(@permission_set, resource.name), notice: added_notice(resource)
    end

    def show
      @tab = TABS.include?(params[:tab]) ? params[:tab] : 'fields'
      load_page
    end

    def review
      @change_set = change_set
      return redirect_to(resource_path, notice: t('permission_forge.flash.permission_sets.no_changes')) if @change_set.empty?

      load_page
      @changes = @change_set.changes
      render 'permission_forge/permission_sets/review'
    end

    def apply
      changes = change_set.apply!
      redirect_to pf_back_or(resource_path),
                  notice: t('permission_forge.flash.permission_sets.saved', count: changes.size,
                                                                            people: helpers.pf_people_text(pf_people_count(@permission_set)))
    rescue PermissionForge::Admin::ChangeSet::Invalid => e
      redirect_to resource_path, alert: t('permission_forge.flash.permission_sets.save_failed', errors: e.message)
    end

    # Sync fields with the model: add new columns at a level, or remove
    # configured fields whose column is gone. All or nothing, so the rows'
    # audit events share one correlation id.
    def sync
      rows = PermissionForge::Admin::FieldRows.new(@resource)
      notice = ActiveRecord::Base.transaction do
        params[:op] == 'remove_missing' ? remove_missing_fields(rows) : add_new_columns(rows)
      end
      redirect_to resource_path, notice: notice
    end

    def confirm_destroy
      @people_count = pf_people_count(@permission_set)
    end

    def destroy
      label = helpers.pf_resource_label(@resource)
      @resource.destroy!
      redirect_to permission_forge.permission_set_path(@permission_set),
                  notice: t('permission_forge.flash.resources.removed', resource: label, set: @permission_set.name)
    end

    private

    def set_permission_set
      @permission_set = PermissionForge::PermissionSet.find(params[:permission_set_id])
    end

    def set_resource
      @resource = @permission_set.resources.includes(:resource_fields, :resource_actions, :permission_set_rules)
                                 .find_by!(name: params[:model])
    end

    def resource_path
      permission_forge.permission_set_resource_path(@permission_set, @resource.name, tab: pf_tab_param(TABS))
    end

    def reject_locked_set
      pf_reject_locked!(@permission_set, permission_forge.permission_set_path(@permission_set))
    end

    def reject_locked_resource
      pf_reject_locked!(@resource, resource_path)
    end

    def change_set
      PermissionForge::Admin::ChangeSet.new(permission_set: @permission_set, params: pf_hash_param(:pf))
    end

    def load_page
      @rows = PermissionForge::Admin::FieldRows.new(@resource)
      @people_count = pf_people_count(@permission_set)
      @impact_people = []
      @lost = []
      @query = params[:q].to_s.strip
      @filter = filter_param(@rows.filters)
      @rules = @resource.permission_set_rules.sort_by(&:created_at)
      @action_rows = PermissionForge::Admin::ActionRows.new(@resource)
    end

    # --- add resource ---------------------------------------------------------

    def filter_param(filters)
      filter = params[:filter]
      filters.include?(filter) ? filter : 'all'
    end

    def remove_missing_fields(rows)
      names = rows.missing_fields.map(&:name)
      @resource.resource_fields.where(name: names).destroy_all
      t('permission_forge.flash.resources.missing_removed', count: names.size)
    end

    def add_new_columns(rows)
      created = create_fields(rows.new_columns, params[:level].to_s)
      t('permission_forge.flash.resources.columns_added', count: created)
    end

    def load_new_form
      load_models
      @sensitive = PermissionForge::Admin::SensitiveColumns.new
      @existing = @permission_set.resources.pluck(:name)
      @presets = @permission_set.is_muting ? MUTING_PRESETS : GRANTING_PRESETS
      preset = params[:preset]
      @preset = @presets.include?(preset) ? preset : @presets.first
      @selected = params[:model_name].to_s
    end

    def load_models
      @catalog = PermissionForge::Admin::ModelCatalog.new
      @query = params[:q].to_s.strip.downcase
      @models = @catalog.models
      @shown = @query.empty? ? @models : @models.select { |m| "#{m.name} #{m.label}".downcase.include?(@query) }
    end

    # Listed (protectable) and not yet in this set.
    def model_error(model)
      return t('permission_forge.errors.admin.resource_model') unless model && @models.any? { |m| m.name == model.name }

      t('permission_forge.errors.admin.resource_taken') if @existing.include?(params[:model_name])
    end

    def added_notice(resource)
      t('permission_forge.flash.resources.added', resource: helpers.pf_resource_label(resource),
                                                  count: resource.resource_fields.size)
    end

    def build_resource(model, preset)
      ActiveRecord::Base.transaction do
        resource = @permission_set.resources.create!(resource_attributes(model, preset))
        # Virtual fields get a row too, so a preset decides them like columns
        # instead of leaving them on the implicit grant.
        create_fields(model.managed_field_names, PRESET_LEVELS[preset], resource: resource)
        PermissionForge.configuration.record_gdpr_pattern_checksum
        resource
      end
    end

    def resource_attributes(model, preset)
      { name: model.name, label: nil, is_active: true, is_editable: true }.merge(PRESET_FLAGS.fetch(preset, {}))
    end

    # Creates ResourceFields for columns and virtual fields at a level, applying
    # privacy defaults (sensitive names start Masked when gdpr_defaults is on).
    def create_fields(columns, level, resource: @resource)
      PermissionForge::Admin::ColumnFields.new(resource, muting: @permission_set.is_muting).create(columns, level)
    end
  end
end
