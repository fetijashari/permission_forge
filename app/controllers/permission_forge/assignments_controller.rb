module PermissionForge
  # Giving and taking access: PermissionSetUser rows. Every change applies
  # immediately (the model invalidates the person's cached permissions) and
  # goes through the model's callbacks, so each grant, change, review and
  # revocation writes its audit event. config.admin_assignment_authorization
  # is asked first (AssignmentAuthorization).
  #
  # @api private
  class AssignmentsController < ApplicationController
    include PermissionForge::AssignmentAuthorization
    include PermissionForge::ActingAdmin
    include PermissionForge::CacheConfirmation

    # What config.admin_assignment_authorization is asked for each member action.
    CHANGE_ACTIONS = { update: :change_expiry, destroy: :revoke, keep: :review }.freeze

    before_action :set_assignment, only: %i[update destroy confirm_destroy keep]
    before_action :change_refused?, only: CHANGE_ACTIONS.keys # redirects when refused
    # Removing a holder of a locked Muting Permission Set gives access back.
    before_action :removal_refused?, only: %i[confirm_destroy destroy] # redirects when refused

    def new
      load_form
    end

    def create
      load_form
      @errors = validate_form
      return render(:new, status: :unprocessable_entity) if @errors.any?

      back = pf_back_or(permission_forge.person_path(@person))
      return if pf_assignment_refused?(@chosen_sets, @person.id, :grant, back)

      created = nil
      outcome = cache_outcome { created = assign_chosen_sets }
      pf_redirect back, undo: assign_undo(created, back), **cache_flash_text(outcome, assigned_notice(created))
    end

    # Change the end date (presets) or extend by 30 days. On a locked
    # Permission Set only a change that narrows access passes
    # (EditableLock.widening_lock): for a granting set an end date set or
    # moved earlier, for a Muting Permission Set one cleared or moved later.
    # Nothing chosen (the select's own first entry), or the end date the
    # assignment has, changes nothing and says so (SaveNotice).
    def update
      expires_at = new_expiry(params[:expiry].to_s)
      return redirect_to(return_path, **pf_save_flash(false)) if expires_at == :invalid
      return if widening_refused?(expires_at)

      outcome = cache_outcome { pf_save_changed(@assignment, { expires_at: expires_at }, &:save!) }
      redirect_to return_path, **pf_save_flash(@assignment) { cache_flash_text(outcome, end_changed_notice(expires_at)) }
    end

    def confirm_destroy
      @lost = lost_labels
    end

    # Removing a holder of a granting set narrows access, also on a locked
    # set; the toast's Undo (which grants again) is offered only where that
    # is allowed (EditableLock.widening_lock).
    def destroy
      name = person_name(@assignment.user)
      set_name = pf_record_name(@assignment.permission_set)
      undo = restore_undo
      outcome = cache_outcome { @assignment.destroy! }
      pf_redirect return_path, undo: undo, **cache_flash_text(outcome, t('permission_forge.flash.assignments.removed', name: name, set: set_name))
    end

    # Access review "Keep": records the reviewer and the date
    # (PermissionSetUser#mark_reviewed!, one assignment.reviewed event);
    # staleness is measured from the last review.
    def keep
      outcome = cache_outcome { @assignment.mark_reviewed!(reviewer: pf_acting_admin_record) }
      redirect_to return_path, **cache_flash_text(outcome, t('permission_forge.flash.assignments.kept',
                                                             name: person_name(@assignment.user), set: pf_record_name(@assignment.permission_set)))
    end

    # Undo for "Remove": recreates the assignment.
    def restore
      expires_at = restored_expiry
      set, user = restore_target
      return if pf_widening_refused?(pf_widening_lock(set, :grant), return_path) || pf_assignment_refused?(set, user.id, :grant, return_path)

      outcome = cache_outcome { restore_assignment(set, user, expires_at) }
      redirect_to return_path,
                  **cache_flash_text(outcome, t('permission_forge.flash.assignments.restored', name: person_name(user), set: pf_record_name(set)))
    end

    # Undo for "Assign": removes the assignments just created (narrows
    # access, so also from a granting set locked since; a locked Muting
    # Permission Set keeps its holders).
    def undo
      assignments = undo_assignments
      return if undo_refused?(assignments)

      outcome = cache_outcome { PermissionForge::Audit.correlate { assignments.each(&:destroy!) } }
      redirect_to return_path, **cache_flash_text(outcome, t('permission_forge.flash.assignments.undone'))
    end

    private

    # An assignment of somebody config.user_list_resolver leaves out is not
    # found: the admin cannot manage them through an assignment id either.
    def set_assignment
      @assignment = PermissionForge::PermissionSetUser.includes(:permission_set, :user).find(params[:id])
      PermissionForge::Admin::PeopleDirectory.new.find(@assignment.user_id) || pf_not_found
    end

    def restore_undo
      return if pf_widening_lock(@assignment.permission_set, :grant)

      # Microseconds: end_of_day is 23:59:59.999999, and IsoTime reads up to 9 fraction digits.
      restore = { 'permission_set_id' => @assignment.permission_set_id, 'user_id' => @assignment.user_id,
                  'expires_at' => @assignment.expires_at&.iso8601(6), 'return_to' => return_path }
      { path: permission_forge.restore_assignments_path, method: 'post', params: restore }
    end

    # A locked set's end dates only move in the narrowing direction.
    def widening_refused?(expires_at)
      locked = pf_widening_lock(@assignment.permission_set, :change_expiry, from: @assignment.expires_at, to: expires_at)
      pf_widening_refused?(locked, return_path)
    end

    def removal_refused?
      pf_widening_refused?(pf_widening_lock(@assignment.permission_set, :revoke), return_path)
    end

    def change_refused?
      pf_assignment_refused?(@assignment.permission_set, @assignment.user_id, CHANGE_ACTIONS.fetch(action_name.to_sym), return_path)
    end

    def restore_target
      [PermissionForge::PermissionSet.find(params[:permission_set_id]),
       PermissionForge::Admin::PeopleDirectory.new.find(params[:user_id]) || pf_not_found]
    end

    def restore_assignment(set, user, expires_at)
      PermissionForge::PermissionSetUser.find_or_create_by!(permission_set: set, user: user) do |assignment|
        assignment.expires_at = expires_at
      end
    end

    def return_path
      pf_back_or(@assignment ? permission_forge.person_path(@assignment.user_id) : permission_forge.people_path)
    end

    def person_name(user)
      PermissionForge::Admin::PersonLabel.new(user).name
    end

    # All or nothing: one transaction (and one correlation id) for every chosen set.
    def assign_chosen_sets
      PermissionForge::PermissionSetUser.transaction do
        @chosen_sets.map do |set|
          PermissionForge::PermissionSetUser.create!(permission_set: set, user: @person, expires_at: @expires_at)
        end
      end
    end

    # Only assignments of people within config.user_list_resolver are
    # undone (an id naming anyone else is not found).
    def undo_assignments
      assignments = PermissionForge::PermissionSetUser.where(id: pf_id_list(:ids)).includes(:permission_set).to_a
      people = PermissionForge::Admin::PeopleDirectory.new.find_all(assignments.map(&:user_id)).map(&:id)
      pf_not_found unless assignments.all? { |assignment| people.include?(assignment.user_id) }
      assignments
    end

    def undo_refused?(assignments)
      assignments.group_by(&:permission_set).any? do |set, rows|
        pf_widening_refused?(pf_widening_lock(set, :revoke), return_path) || pf_assignment_refused?(set, rows.map(&:user_id), :revoke, return_path)
      end
    end

    # --- assign form state ------------------------------------------------------

    def load_form
      load_person
      load_sets
      @people_counts = PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
      pf_load_expiry
      @chosen_sets = @sets.select do |set|
        @selected_ids.include?(set.id) && !@existing_ids.include?(set.id) && !@locked_ids.include?(set.id)
      end
    end

    def load_person
      @person = person_chosen? ? PermissionForge::Admin::PeopleDirectory.new.find(params[:user_id]) : nil
      @query = params[:q].to_s.strip
      @people = @person ? nil : PermissionForge::Admin::PeopleDirectory.new.pick(query: @query, limit: picker_limit)
      @existing_ids = @person ? PermissionForge::PermissionSetUser.where(user_id: @person.id).pluck(:permission_set_id) : []
    end

    # A person was picked (and the form is not switching or searching people).
    def person_chosen?
      params[:user_id].present? && params[:change_person].blank? && params[:search].blank?
    end

    def load_sets
      @set_query = pf_text_param(:set_q)
      @preset_set = PermissionForge::PermissionSet.find_by(id: params[:permission_set_id])
      @selected_ids = (pf_id_list(:set_ids) + [@preset_set&.id]).compact.uniq
      @sets = listed_sets
      @locked_ids = @sets.select { |set| pf_widening_lock(set, :grant) }.to_set(&:id)
    end

    def picker_limit
      @person ? 0 : 8
    end

    # Every set matching the filter. Those a holder cannot be added to (that
    # widens access on a locked set; a locked Muting Permission Set takes
    # holders) are listed as locked (@locked_ids) and never chosen.
    def listed_sets
      scope = PermissionForge::PermissionSet.order(:is_muting, :name)
      unless @set_query.empty?
        needle = "%#{ActiveRecord::Base.sanitize_sql_like(@set_query.downcase)}%"
        scope = scope.where('LOWER(name) LIKE ?', needle).or(scope.where(id: @selected_ids))
      end
      scope.to_a
    end

    def validate_form
      errors = {}
      errors[:person] = t('permission_forge.errors.admin.person') unless @person
      errors[:sets] = t('permission_forge.errors.admin.sets') if @chosen_sets.empty?
      expiry_error = pf_resolve_expiry
      errors[:expiry] = expiry_error if expiry_error
      errors
    end

    def assign_undo(created, back)
      { path: permission_forge.undo_assignments_path, method: 'post',
        params: { 'ids' => created.map(&:id), 'return_to' => back } }
    end

    def end_changed_notice(expires_at)
      t('permission_forge.flash.assignments.end_changed', name: person_name(@assignment.user),
                                                          set: pf_record_name(@assignment.permission_set),
                                                          when: helpers.pf_expiry(expires_at).first)
    end

    # A date that cannot be read is a 400: it must never restore the
    # assignment without an end date.
    def restored_expiry = pf_time_param(:expires_at)

    def assigned_notice(created)
      sets = helpers.pf_to_sentence(created.map { |assignment| pf_record_name(assignment.permission_set) })
      return t('permission_forge.flash.assignments.assigned', name: person_name(@person), sets: sets) if @expires_at.nil?

      t('permission_forge.flash.assignments.assigned_until', name: person_name(@person), sets: sets,
                                                             date: helpers.pf_date(@expires_at, year: false))
    end

    # :invalid for a blank or unknown key (CHANGE_KEYS has no blank entry).
    def new_expiry(key)
      PermissionForge::Admin::ExpiryPresets.change_to(key, from: @assignment.expires_at)
    end

    # What the person stops seeing when this (granting) assignment is removed.
    def lost_labels
      permission_set = @assignment.permission_set
      return [] if permission_set.is_muting

      permission_set.resources.in_effect.map { |r| helpers.pf_resource_plural(r.name) }
    end
  end
end
