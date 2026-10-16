module PermissionForge
  # Loads the one-page Permission Set editor and its tabs (resources matrix,
  # assignments, conditions, audit) for PermissionSetsController. Tabs are
  # dispatched as load_<tab>_tab.
  #
  # @api private
  module PermissionSetEditor
    AUDIT_TIMELINE_PER_PAGE = 20

    private

    def load_editor
      @resources = @permission_set.resources.includes(:resource_fields, :resource_actions, :permission_set_rules).order(:name).to_a
      @groups = PermissionForge::PermissionSetGroup.order(:name)
      load_impact
      @assignment_count = @permission_set.permission_set_users.count
    end

    def load_impact
      live = @permission_set.permission_set_users.active_assignments.includes(:user).order(:created_at)
      @people_count = live.count
      @impact_people = live.limit(3).map(&:user).compact
      @lost = @permission_set.is_muting ? [] : @permission_set.resources.in_effect.map { |r| helpers.pf_resource_plural(r.name) }
    end

    def load_resources_tab
      @catalog = PermissionForge::Admin::ModelCatalog.new
    end

    def load_assignments_tab
      @assignments = @permission_set.permission_set_users.includes(:user).order(:created_at).to_a
    end

    def load_conditions_tab
      @ip_text ||= helpers.pf_ip_list(@permission_set.allowed_ips).join("\n")
      configured = (PermissionForge.configuration.admin_session_flags || {}).keys.map(&:to_s)
      used = PermissionForge::PermissionSet.where.not(requires_session_flag: [nil, '']).distinct.pluck(:requires_session_flag)
      @flag_options = (configured + used).uniq
    end

    def load_audit_tab
      load_audit_filters
      audit = PermissionForge::Admin::AuditTrail.new
      @editors = PermissionForge::Admin::AuditTrail.editors(audit.for_permission_set(@permission_set))
      @entries = audit.for_permission_set(@permission_set, who: @who, type: @type, days: @days, sort: @sort)
      load_audit_timeline unless request.format.csv?
    end

    # The set's events, newest first (the log filtered by this set).
    def load_audit_timeline
      @timeline_log = PermissionForge::Admin::AuditLog.new({ views: @views },
                                                           scope: PermissionForge::Admin::AuditLog.for_permission_set(@permission_set))
      @timeline = @timeline_log.page(params[:page], per_page: AUDIT_TIMELINE_PER_PAGE)
      @timeline_lookups = PermissionForge::Admin::AuditLookups.new(@timeline.events)
    end

    # Typed like every admin parameter (ParamShapes): a Hash or a list in
    # one of them is no filter, never a 500. Days are one of the offered
    # counts (AuditTrail::DAY_FILTERS), else no filter.
    def load_audit_filters
      @who = pf_text_param(:who).presence
      @type = pf_text_param(:type).presence
      offered = PermissionForge::Admin::AuditTrail::DAY_FILTERS
      @days = pf_integer_param(:days, default: nil, range: 1..offered.max).then { |days| days if offered.include?(days) }
      @sort = params[:sort] == 'asc' ? 'asc' : 'desc'
      @views = pf_text_param(:views).presence
    end

    def send_audit_csv
      audit = PermissionForge::Admin::AuditTrail.new
      csv = audit.to_csv(@entries, describe: helpers.method(:pf_audit_csv_describe), person: helpers.method(:pf_audit_people))
      response.headers['Cache-Control'] = 'no-store' # names of people, like the log's exports
      send_data csv, filename: "permission-forge-#{@permission_set.name.parameterize}-audit.csv", type: 'text/csv'
    end
  end
end
