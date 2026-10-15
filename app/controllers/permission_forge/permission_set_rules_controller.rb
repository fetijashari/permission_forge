module PermissionForge
  # Record rules (row-level filters) for a Resource, built as sentences.
  #
  # @api private
  class PermissionSetRulesController < ApplicationController
    before_action :set_resource
    before_action :set_rule, only: %i[edit update destroy confirm_destroy toggle]
    before_action :reject_locked
    helper_method :rule_builder

    def new
      @form = PermissionForge::Admin::RuleForm.new(resource: @resource)
    end

    def create
      @form = PermissionForge::Admin::RuleForm.new(resource: @resource, params: rule_params)
      @rule = @resource.permission_set_rules.build(permission_set: @permission_set)
      save_rule(:new, 'created')
    end

    def edit
      @form = PermissionForge::Admin::RuleForm.new(resource: @resource, rule: @rule)
    end

    def update
      @form = PermissionForge::Admin::RuleForm.new(resource: @resource, params: rule_params)
      save_rule(:edit, 'updated')
    end

    # Re-renders the builder after a relationship/field/operator change.
    def refresh
      @form = PermissionForge::Admin::RuleForm.new(resource: @resource, params: rule_params)
      @rule = @resource.permission_set_rules.find_by(id: params[:rule_id])
      render(@rule ? :edit : :new)
    end

    def toggle
      @rule.update!(is_active: !@rule.is_active)
      key = @rule.is_active ? 'turned_on' : 'turned_off'
      redirect_to rules_path, notice: t("permission_forge.flash.rules.#{key}", rule: @rule.name)
    end

    def confirm_destroy; end

    def destroy
      name = @rule.name
      @rule.destroy!
      redirect_to rules_path, notice: t('permission_forge.flash.rules.deleted', rule: name)
    end

    private

    # What the builder page draws: built here, read by the template.
    def rule_builder
      @rule_builder ||= PermissionForge::Admin::RuleBuilder.new(form: @form, resource: @resource, model_errors: @model_errors,
                                                                rule: @rule)
    end

    def set_resource
      @permission_set = PermissionForge::PermissionSet.find(params[:permission_set_id])
      @resource = @permission_set.resources.find_by!(name: params[:resource_model])
    end

    def set_rule
      @rule = @resource.permission_set_rules.find(params[:id])
    end

    def reject_locked
      locked = [@permission_set, @resource, @rule].compact.find { |r| pf_locked?(r) }
      pf_reject_locked!(locked, rules_path) if locked
    end

    def rules_path
      permission_forge.permission_set_resource_path(@permission_set, @resource.name, tab: 'rules')
    end

    def rule_params
      pf_hash_param(:rule).permit(:name, :field_name, :operator, :value, :values_text, :value_from, :value_to,
                                  :current_user, :include_nulls, :failure_message, :join, :is_active, :remove_step,
                                  path: [], values: [])
    end

    def save_rule(template, flash_key)
      unless @form.valid?
        @people_count = pf_people_count(@permission_set)
        return render(template, status: :unprocessable_entity)
      end

      @rule.assign_attributes(@form.attributes)
      if @rule.save
        redirect_to rules_path, notice: t("permission_forge.flash.rules.#{flash_key}", rule: @rule.name)
      else
        @model_errors = @rule.errors.full_messages
        render template, status: :unprocessable_entity
      end
    end
  end
end
