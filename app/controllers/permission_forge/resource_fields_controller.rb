module PermissionForge
  # Field detail (drawer or page) for one column of a Resource — configured or
  # not yet configured. Saves apply immediately (with an impact line).
  #
  # @api private
  class ResourceFieldsController < ApplicationController
    include PermissionForge::ActingAdmin

    before_action :load_field
    before_action :reject_locked, only: %i[update acknowledge apply_recommendation]

    def show
      row = @rows.row(@key)
      @detail = PermissionForge::Admin::FieldDetail.new(
        resource: @resource, row: row, rows: @rows,
        rules: field_rules, across: PermissionForge::Admin::FieldAcrossSets.call(@resource.name, @key),
        people_count: pf_people_count(@permission_set), explain_people: explain_candidates,
        explain: (explain(params[:explain_user_id]) if params[:explain_user_id].present?),
        explain_user_id: params[:explain_user_id]
      )
    end

    def update
      attrs = pf_require_hash(:field).permit(:level, :mask_strategy, :label, :description, :is_active).to_h
      changes = apply_field_changes(attrs)
      finish_new_field(attrs) unless @field
      redirect_to pf_back_or(resource_path), notice: saved_notice(changes)
    rescue PermissionForge::Admin::ChangeSet::Invalid => e
      redirect_to field_path, alert: t('permission_forge.flash.permission_sets.save_failed', errors: e.message)
    end

    # Privacy audit: "This is intended" — stop flagging this unmasked field.
    # Records who acknowledged it (sensitive_acknowledged_by_id, when the
    # column exists) through a normal update: one field.sensitive_acknowledged event.
    def acknowledge
      if @field && PermissionForge::Admin::AttentionItems.acknowledgement_supported?
        attrs = { sensitive_acknowledged_at: Time.current }
        attrs[:sensitive_acknowledged_by_id] = pf_acting_admin_record&.id if @field.has_attribute?(:sensitive_acknowledged_by_id)
        @field.audit_as('field.sensitive_acknowledged') { @field.update!(attrs) }
      end
      redirect_to pf_back_or(field_path), notice: t('permission_forge.flash.fields.acknowledged', field: @key)
    end

    # Applies the recommended mask for a sensitive column.
    def apply_recommendation
      match = PermissionForge::SensitiveColumns.new.match(@key)
      return redirect_to(field_path) unless match

      level = @permission_set.is_muting ? 'mask' : 'masked'
      apply_field_changes('level' => level, 'mask_strategy' => match.strategy)
      redirect_to pf_back_or(field_path), notice: t('permission_forge.flash.fields.recommendation_applied', field: @key)
    end

    private

    def load_field
      load_resource
      @key = params[:key].to_s
      @field = @resource.resource_fields.find { |field| field.name == @key }
      @rows = PermissionForge::Admin::FieldRows.new(@resource)
      pf_not_found unless @field || @rows.row(@key)
    end

    def load_resource
      @permission_set = PermissionForge::PermissionSet.find(params[:permission_set_id])
      @resource = @permission_set.resources.includes(:resource_fields, :permission_set_rules).find_by!(name: params[:resource_model])
    end

    # Applies `attrs` to this field through a ChangeSet; an unconfigured column
    # is created at attrs['level'].
    def apply_field_changes(attrs)
      change_params = if @field
                        { fields: { @field.id.to_s => attrs } }
                      else
                        { new_fields: { @resource.id.to_s => { @key => { 'level' => attrs['level'] } } } }
                      end
      PermissionForge::Admin::ChangeSet.new(permission_set: @permission_set, params: change_params).apply!
    end

    # Filter rules (no relationship) on this field.
    def field_rules
      @resource.permission_set_rules.select { |rule| rule.field_name == @key && rule.field_accessor_path.blank? }
    end

    # The field's chain (field, Resource, Permission Set), or the Resource's for a column with no row.
    def reject_locked
      pf_reject_locked!(@field || @resource, field_path)
    end

    def resource_path
      permission_forge.permission_set_resource_path(@permission_set, @resource.name)
    end

    def field_path
      permission_forge.permission_set_resource_field_path(@permission_set, @resource.name, @key)
    end

    def finish_new_field(attrs)
      field = @resource.resource_fields.reload.find { |candidate| candidate.name == @key }
      return unless field

      extra = attrs.slice('label', 'description').compact_blank
      extra['mask_strategy'] = attrs['mask_strategy'] if attrs['mask_strategy'].present? && field.mask_access
      field.update!(extra) if extra.any?
    end

    def saved_notice(changes)
      return t('permission_forge.flash.permission_sets.no_changes') if changes.empty?

      t('permission_forge.flash.permission_sets.saved', count: changes.size,
                                                        people: helpers.pf_people_text(pf_people_count(@permission_set)))
    end

    # People holding a set with this Resource, or one of the STI bases its
    # records answer to (ResourceChain: a base's rows reach the subclass).
    def explain_candidates
      set_ids = PermissionForge::Resource.where(name: chain_names).select(:permission_set_id)
      user_ids = PermissionForge::PermissionSetUser.active_assignments.where(permission_set_id: set_ids)
                                                   .distinct.limit(200).pluck(:user_id)
      PermissionForge::Admin::PeopleDirectory.new.find_all(user_ids)
    end

    def explain(user_id)
      user = PermissionForge::Admin::PeopleDirectory.new.find(user_id)
      return nil unless user

      outcome = nearest_outcome(PermissionForge::Admin::EffectiveAccess.call(user: user))
      { user: user, field: outcome&.fields&.find { |field| field.name == @key } }
    end

    def chain_names
      PermissionForge::ResourceChain.names_for(@resource.name).map(&:to_s)
    end

    # The person's outcome for this model: its own entry, else the nearest
    # base's (a subclass without an entry of its own is its base).
    def nearest_outcome(outcomes)
      chain_names.each do |name|
        outcome = outcomes.find { |r| r.name == name }
        return outcome if outcome
      end
      nil
    end
  end
end
