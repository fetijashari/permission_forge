module PermissionForge
  # People: everyone in the host app, what they can access, and why.
  #
  # @api private
  class PeopleController < ApplicationController
    include PermissionForge::CacheConfirmation
    include PermissionForge::AssignmentAuthorization
    include PermissionForge::AuditLogGate

    PER_PAGE = 25
    TABS = %w[access effective audit].freeze
    # Records listed per type under "Changes made by" (the CSV has them all).
    CHANGES_SHOWN = 100
    TIMELINE_PER_PAGE = 20

    pf_exports %i[csv], only: :show # the person's changes
    before_action :set_person, except: %i[index]

    def index
      @query = params[:q].to_s.strip
      @filter = filter_param
      @page = directory.search(query: @query, filter: @filter, page: params[:page], per_page: PER_PAGE)
      @counts = directory.counts(query: @query)
      @assignments = assignments_for(@page.people.map(&:id))
    end

    def show
      @tab = TABS.include?(params[:tab]) ? params[:tab] : 'access'
      @assignments = @person_assignments
      @groups = PermissionForge::PermissionSetGroupUser.where(user_id: @person.id).includes(:permission_set_group)
      return pf_refuse_audit_tab unless pf_audit_tab_allowed?

      send("load_#{@tab}_tab")
      respond_to do |format|
        format.html
        format.csv { send_changes_csv }
      end
    end

    # --- offboarding ------------------------------------------------------------

    def confirm_remove_all
      load_removable
      @lost = lost_resource_labels(@removable)
    end

    # Each assignment is destroyed through its callbacks (one
    # assignment.revoked event each, sharing one correlation id). Granting
    # sets lose the person also when locked; a locked Muting Permission Set
    # keeps them (removing them would give access back — EditableLock).
    def remove_all
      load_removable
      sets = @removable.map(&:permission_set).uniq
      path = permission_forge.person_path(@person)
      return if pf_assignment_refused?(sets, @person.id, :revoke, path)

      count = @removable.size
      outcome = cache_outcome { PermissionForge::Audit.correlate { @removable.each(&:destroy!) } }
      redirect_to permission_forge.person_path(@person),
                  **cache_flash(outcome, { notice: :removed_all, alert: :removed_all_cache_kept }, count: count, name: person_name)
    end

    def refresh_cache
      outcome = cache_outcome { @person.invalidate_permissions if @person.respond_to?(:invalidate_permissions) }
      redirect_to permission_forge.person_path(@person, tab: pf_tab_param(TABS)),
                  **cache_flash(outcome, { notice: :cache_refreshed, alert: :cache_refresh_failed }, name: person_name)
    end

    # --- consent withdrawal -------------------------------------------------------

    def consent_preview
      @flags = consent_flags
      @flag = params[:flag].presence || @flags.first
      @affected = @person_assignments.select { |assignment| @flag.present? && assignment.permission_set.requires_session_flag == @flag }
    end

    def withdraw_consent
      flag = params[:flag].to_s
      return redirect_to(permission_forge.person_path(@person)) unless consent_flags.include?(flag)

      result = consent_service(flag, dry_run: false)
      # the service's one cache outcome (nothing revoked: nothing to clear, confirmed)
      redirect_to permission_forge.person_path(@person),
                  **cache_flash(result[:cache], { notice: :consent_withdrawn, alert: :consent_withdrawn_cache_kept },
                                count: result[:revoked_sets], flag: flag)
    end

    # --- erasure ----------------------------------------------------------------------

    def erasure_preview
      @preview = erasure_service(dry_run: true)
    end

    def erase
      if params[:confirmation].to_s.strip != person_name
        @preview = erasure_service(dry_run: true)
        @confirmation_error = true
        return render :erasure_preview, status: :unprocessable_entity
      end

      result = erasure_service(dry_run: false)
      # the service's one cache outcome (confirmed nil: erased inside a transaction of the host's, the cache follows at its commit)
      redirect_to permission_forge.people_path,
                  **cache_flash(result[:cache], { notice: :erased, alert: :erased_cache_kept }, name: person_name)
    end

    private

    def directory
      @directory ||= PermissionForge::Admin::PeopleDirectory.new
    end

    def filter_param
      filter = params[:filter]
      PermissionForge::Admin::PeopleDirectory::FILTERS.include?(filter) ? filter : 'all'
    end

    def set_person
      @person = directory.find(params[:id]) || pf_not_found
      @person_assignments = PermissionForge::PermissionSetUser.where(user_id: @person.id)
                                                              .includes(:permission_set).order(:created_at).to_a
    end

    def person_name
      PermissionForge::Admin::PersonLabel.new(@person).name
    end

    # @removable: the assignments "Remove all access" removes; @kept: those
    # of locked Muting Permission Sets, where removing widens access.
    def load_removable
      @kept, @removable = @person_assignments.partition do |assignment|
        pf_widening_lock(assignment.permission_set, :revoke)
      end
    end

    def assignments_for(user_ids)
      PermissionForge::PermissionSetUser.where(user_id: user_ids).includes(:permission_set).group_by(&:user_id)
    end

    def load_access_tab; end

    def load_effective_tab
      service = PermissionForge::Admin::EffectiveAccess.new(user: @person)
      @effective = service.call
      @conditional_sets = service.conditional_sets
      @open = Array(params[:open]).map(&:to_s)
      @why = params[:why].to_s
    end

    def load_audit_tab
      @changes = audit.changes_by(@person.id, limit: CHANGES_SHOWN)
      @changes_capped = audit.capped?
      @timeline_log = PermissionForge::Admin::AuditLog.new({ views: params[:views] },
                                                           scope: PermissionForge::Admin::AuditLog.for_person(@person.id))
      @timeline = @timeline_log.page(params[:page], per_page: TIMELINE_PER_PAGE)
      @timeline_lookups = PermissionForge::Admin::AuditLookups.new(@timeline.events)
    end

    def audit
      @audit ||= PermissionForge::Admin::AuditTrail.new
    end

    def send_changes_csv
      entries = audit.changes_by(@person.id).values.flatten
      csv = audit.to_csv(entries, describe: helpers.method(:pf_audit_describe), person: helpers.method(:pf_audit_people))
      response.headers['Cache-Control'] = 'no-store' # names of people, like the log's exports
      send_data csv, filename: "permission-forge-changes-#{@person.id}.csv", type: 'text/csv'
    end

    def lost_resource_labels(assignments)
      assignments.map(&:permission_set).reject(&:is_muting)
                 .flat_map { |ps| ps.resources.in_effect.map { |r| helpers.pf_resource_plural(r.name) } }.uniq
    end

    # Flags gating sets this person has, plus configured flags.
    def consent_flags
      flags = @person_assignments.map { |assignment| assignment.permission_set.requires_session_flag }.compact_blank
      (flags + (PermissionForge.configuration.admin_session_flags || {}).keys.map(&:to_s)).uniq
    end

    def consent_service(flag, dry_run:)
      PermissionForge::Services::ConsentWithdrawalHandler.call(user: @person, consent_flag: flag, dry_run: dry_run)
    end

    def erasure_service(dry_run:)
      PermissionForge::Services::DataSubjectErasure.call(user: @person, dry_run: dry_run)
    end
  end
end
