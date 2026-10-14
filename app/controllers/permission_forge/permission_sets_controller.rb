module PermissionForge
  # Permission Sets: list, create (granting or muting), and the one-page
  # editor (resources matrix, assignments, conditions, audit).
  #
  # @api private
  class PermissionSetsController < ApplicationController
    include PermissionSetEditor
    include PermissionForge::AuditLogGate

    FILTERS = %w[all granting muting conditional off].freeze
    TABS = %w[resources assignments conditions audit].freeze

    # List filter => predicate on a set ('all' and unknown filters match everything).
    FILTER_MATCHERS = {
      'granting' => ->(set) { !set.is_muting },
      'muting' => lambda(&:is_muting),
      'conditional' => lambda(&:conditional?),
      'off' => ->(set) { !set.is_active }
    }.freeze

    pf_exports %i[csv], only: :show # the audit tab
    before_action :set_permission_set, except: %i[index new create]
    before_action :reject_locked, only: %i[review apply destroy confirm_destroy switch_mode confirm_switch_mode conditions]
    before_action :reject_locked_group_move, only: %i[create review apply]

    def index
      @query = params[:q].to_s.strip
      @filter = filter_param
      all = PermissionForge::PermissionSet.includes(:permission_set_group, :resources).order(:name).to_a
      @total = all.size
      @counts = filter_counts(all)
      @permission_sets = all.select { |ps| filter_match?(ps, @filter) && query_match?(ps) }
      @people_counts = people_counts
    end

    def new
      @muting = params[:type] == 'muting'
      @name = params[:name].to_s
      load_new_form
    end

    def create
      @muting = params[:type] == 'muting'
      @name = pf_text_param(:name)
      load_new_form
      @error = name_error(@name)
      return render(:new, status: :unprocessable_entity) if @error

      set = build_set
      redirect_to permission_forge.permission_set_path(set), notice: t('permission_forge.flash.permission_sets.created', name: set.name)
    end

    def show
      # The CSV is the audit tab's export, whatever tab the link came from.
      @tab = if request.format.csv?
               'audit'
             else
               (TABS.include?(params[:tab]) ? params[:tab] : 'resources')
             end
      load_editor
      return pf_refuse_audit_tab unless pf_audit_tab_allowed?

      send("load_#{@tab}_tab")
      respond_to do |format|
        format.html
        format.csv { send_audit_csv }
      end
    end

    # "Review and save": lists every pending change and who it affects.
    def review
      @change_set = change_set
      if @change_set.empty?
        return redirect_to(pf_back_or(permission_forge.permission_set_path(@permission_set)),
                           notice: t('permission_forge.flash.permission_sets.no_changes'))
      end

      load_editor
      @changes = @change_set.changes
      render :review
    end

    def apply
      changes = change_set.apply!
      redirect_to back_to_set, notice: t('permission_forge.flash.permission_sets.saved',
                                         count: changes.size, people: helpers.pf_people_text(pf_people_count(@permission_set)))
    rescue PermissionForge::Admin::ChangeSet::Invalid => e
      redirect_to back_to_set, alert: t('permission_forge.flash.permission_sets.save_failed', errors: e.message)
    end

    def duplicate
      name = PermissionForge::Admin::PermissionSetFactory.unique_name(
        t('permission_forge.permission_sets.copy_name', name: @permission_set.name)
      )
      copy = PermissionForge::Admin::PermissionSetFactory.duplicate(@permission_set, name: name)
      group = @permission_set.permission_set_group
      notice = if group && copy.permission_set_group_id.nil?
                 t('permission_forge.flash.permission_sets.duplicated_outside_group', name: @permission_set.name, group: group.name)
               else
                 t('permission_forge.flash.permission_sets.duplicated', name: @permission_set.name)
               end
      redirect_to permission_forge.permission_set_path(copy), notice: notice
    end

    def confirm_destroy
      load_impact
    end

    def destroy
      name = @permission_set.name
      @permission_set.destroy!
      redirect_to permission_forge.permission_sets_path, notice: t('permission_forge.flash.permission_sets.deleted', name: name)
    end

    def confirm_switch_mode
      load_impact
    end

    # Granting <-> muting. Field flags are kept; their meaning inverts.
    def switch_mode
      @permission_set.update!(is_muting: !@permission_set.is_muting)
      key = @permission_set.is_muting ? 'switched_muting' : 'switched_granting'
      redirect_to permission_forge.permission_set_path(@permission_set),
                  notice: t("permission_forge.flash.permission_sets.#{key}", name: @permission_set.name)
    end

    def conditions
      @conditions_form = PermissionForge::Admin::ConditionsForm.new(params) # the re-render reads it back
      attrs = @conditions_form.attributes
      @condition_errors = @conditions_form.errors
      if @condition_errors.empty? && @permission_set.update(attrs)
        return redirect_to permission_forge.permission_set_path(@permission_set, tab: 'conditions'),
                           notice: t('permission_forge.flash.permission_sets.conditions_saved')
      end

      @tab = 'conditions'
      @ip_text = params[:allowed_ips].to_s
      load_editor
      load_conditions_tab
      render :show, status: :unprocessable_entity
    end

    private

    def set_permission_set
      @permission_set = PermissionForge::PermissionSet.find(params[:id])
    end

    # Deleting the set also changes its group's list of sets: a locked group
    # refuses it (EditableLock.container_of).
    def reject_locked
      container = PermissionForge::Admin::EditableLock.container_of(@permission_set) if action_name.include?('destroy')
      pf_reject_locked!([@permission_set, container], permission_forge.permission_set_path(@permission_set))
    end

    # A set created in, or moved into or out of, a locked Permission Set
    # Group changes that group's list of sets: refused, as on the group page.
    def reject_locked_group_move
      requested = @permission_set ? pf_hash_param(:pf)[:set] : params
      return unless requested.respond_to?(:key?) && requested.key?(:permission_set_group_id)

      locked = PermissionForge::Admin::EditableLock.locked_group_for_move(
        from: @permission_set&.permission_set_group_id, to: requested[:permission_set_group_id]
      )
      back = @permission_set ? permission_forge.permission_set_path(@permission_set) : permission_forge.permission_sets_path
      pf_reject_locked!(locked, back) if locked
    end

    def back_to_set
      pf_back_or(permission_forge.permission_set_path(@permission_set))
    end

    def change_set
      PermissionForge::Admin::ChangeSet.new(permission_set: @permission_set, params: pf_hash_param(:pf))
    end

    # --- list -----------------------------------------------------------------

    def filter_param
      filter = params[:filter]
      FILTERS.include?(filter) ? filter : 'all'
    end

    def filter_counts(sets)
      FILTERS.index_with { |filter| sets.count { |ps| filter_match?(ps, filter) } }
    end

    def filter_match?(set, filter)
      matcher = FILTER_MATCHERS[filter]
      matcher ? matcher.call(set) : true
    end

    def query_match?(set)
      return true if @query.empty?

      needle = @query.downcase
      [set.name, set.description].compact.any? { |v| v.downcase.include?(needle) }
    end

    def people_counts
      PermissionForge::PermissionSetUser.active_assignments.group(:permission_set_id).count
    end

    # --- create / duplicate -----------------------------------------------------

    def load_new_form
      @groups = PermissionForge::PermissionSetGroup.order(:name)
      @sources = PermissionForge::PermissionSet.order(:name).to_a
      @start_from = params[@muting ? :start_from_muting : :start_from_granting].to_s
      @group_id = params[:permission_set_group_id].to_s
    end

    def name_error(name)
      return t('permission_forge.errors.admin.set_name_blank') if name.blank?
      return t('permission_forge.errors.admin.set_name_taken') if PermissionForge::Admin::PermissionSetFactory.name_taken?(name)

      nil
    end

    def build_set
      group = PermissionForge::PermissionSetGroup.find_by(id: @group_id)
      source = @sources.find { |ps| ps.id.to_s == @start_from && ps.is_muting == @muting }
      PermissionForge::Admin::PermissionSetFactory.create({ name: @name, is_muting: @muting, permission_set_group: group },
                                                          source: source)
    end
  end
end
