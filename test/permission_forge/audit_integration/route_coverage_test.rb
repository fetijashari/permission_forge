# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # Every route of the engine that is not a GET or HEAD — admin UI and API —
    # is listed in ROUTES with the audit events it writes, or with the reason
    # it writes none. A route that is not listed fails the suite: a new write
    # path cannot ship without saying what it records.
    #
    # Each listed route is then driven on its happy path (once per way of
    # acting: a signed-in admin and HTTP Basic in the admin UI, an API token
    # named by audit_actor_resolver in the API; the drive_* method arranges
    # its data, then makes ONE request), and the request must write
    # exactly the listed events, each with the request's actor, its source,
    # the `reason` sent with it and the request id, all under ONE
    # correlation id; the drive_* method checks the record and the
    # before/after (data['changes'] or data['snapshot']).
    class RouteCoverageTest < ActionDispatch::IntegrationTest
      include IntegrationSupport

      HOW_TO_ADD = <<~TEXT.freeze
        Add it to ROUTES in #{__FILE__}:
          'controller#action' => { verbs: %w[POST], events: %w[model.created], drive: :name }   # what it records
          'controller#action' => { verbs: %w[POST], none: 'why it changes nothing audited', drive: :name }
        and a drive_<name> method that performs it on its happy path (and checks the record and before/after).
      TEXT

      # endpoint => { verbs:, events: [...] | none: 'reason', drive: }
      ROUTES = {
        # --- admin UI -----------------------------------------------------------------
        'permission_forge/preferences#update' => { verbs: %w[PATCH PUT], drive: :preferences,
                                                   none: 'per-browser cookies (theme, dismissed help): no permission data' },
        'permission_forge/maintenance#cleanup' => { verbs: %w[DELETE], drive: :cleanup,
                                                    events: %w[assignment.revoked cleanup.expired_assignments] },
        'permission_forge/people#remove_all' => { verbs: %w[DELETE], drive: :remove_all, events: %w[assignment.revoked] },
        'permission_forge/people#refresh_cache' => {
          verbs: %w[POST], drive: :refresh_cache,
          none: 'drops the cached permission hash only (permissions.invalidated is a runtime event of the :cache group)'
        },
        'permission_forge/people#withdraw_consent' => { verbs: %w[POST], drive: :withdraw_consent,
                                                        events: %w[assignment.revoked consent.withdrawn] },
        'permission_forge/people#erase' => { verbs: %w[POST], drive: :erase,
                                             events: %w[assignment.revoked erasure.performed group_membership.removed] },
        'permission_forge/assignments#keep' => { verbs: %w[POST], drive: :keep, events: %w[assignment.reviewed] },
        'permission_forge/assignments#restore' => { verbs: %w[POST], drive: :restore, events: %w[assignment.granted] },
        'permission_forge/assignments#undo' => { verbs: %w[POST], drive: :undo, events: %w[assignment.revoked] },
        'permission_forge/assignments#create' => { verbs: %w[POST], drive: :assign, events: %w[assignment.granted] },
        'permission_forge/assignments#update' => { verbs: %w[PATCH PUT], drive: :change_expiry, events: %w[assignment.changed] },
        'permission_forge/assignments#destroy' => { verbs: %w[DELETE], drive: :revoke, events: %w[assignment.revoked] },
        'permission_forge/permission_sets#review' => { verbs: %w[POST], drive: :set_review,
                                                       none: 'Review-and-save preview: renders the pending changes, saves nothing' },
        'permission_forge/permission_sets#apply' => { verbs: %w[PATCH], drive: :set_apply,
                                                      events: %w[permission_set.updated resource.updated] },
        'permission_forge/permission_sets#duplicate' => {
          verbs: %w[POST], drive: :set_duplicate,
          events: %w[permission_set.cloned permission_set.created permission_set_rule.created resource.created
                     resource_action.created resource_field.created]
        },
        'permission_forge/permission_sets#switch_mode' => { verbs: %w[PATCH], drive: :switch_mode, events: %w[permission_set.updated] },
        'permission_forge/permission_sets#conditions' => { verbs: %w[PATCH], drive: :conditions, events: %w[permission_set.updated] },
        'permission_forge/permission_sets#create' => { verbs: %w[POST], drive: :set_create, events: %w[permission_set.created] },
        'permission_forge/permission_sets#destroy' => {
          verbs: %w[DELETE], drive: :set_destroy,
          events: %w[assignment.revoked permission_set.destroyed permission_set_rule.destroyed resource.destroyed
                     resource_action.destroyed resource_field.destroyed]
        },
        'permission_forge/bulk_assignments#preview' => { verbs: %w[POST], drive: :bulk_preview,
                                                         none: 'shows who would be assigned, assigns nobody' },
        'permission_forge/bulk_assignments#create' => { verbs: %w[POST], drive: :bulk_assign, events: %w[assignment.granted] },
        'permission_forge/bulk_assignments#revoke' => { verbs: %w[DELETE], drive: :bulk_revoke, events: %w[assignment.revoked] },
        'permission_forge/resources#review' => { verbs: %w[POST], drive: :resource_review,
                                                 none: 'Review-and-save preview: renders the pending changes, saves nothing' },
        'permission_forge/resources#apply' => { verbs: %w[PATCH], drive: :resource_apply, events: %w[resource.updated] },
        'permission_forge/resources#sync' => { verbs: %w[POST], drive: :sync, events: %w[resource_field.destroyed] },
        'permission_forge/resources#create' => { verbs: %w[POST], drive: :resource_create,
                                                 events: %w[resource.created resource_field.created] },
        'permission_forge/resources#destroy' => {
          verbs: %w[DELETE], drive: :resource_destroy,
          events: %w[permission_set_rule.destroyed resource.destroyed resource_action.destroyed resource_field.destroyed]
        },
        'permission_forge/resource_fields#acknowledge' => { verbs: %w[POST], drive: :acknowledge,
                                                            events: %w[field.sensitive_acknowledged] },
        'permission_forge/resource_fields#apply_recommendation' => { verbs: %w[POST], drive: :apply_recommendation,
                                                                     events: %w[resource_field.updated] },
        # A column not configured yet: created by a Review-and-save, then
        # labelled in a second transaction — only the request's correlation
        # id ties the two events together.
        'permission_forge/resource_fields#update' => { verbs: %w[PATCH PUT], drive: :field_update,
                                                       events: %w[resource_field.created resource_field.updated] },
        'permission_forge/resource_actions#create' => { verbs: %w[POST], drive: :action_create, events: %w[resource_action.created] },
        'permission_forge/resource_actions#update' => { verbs: %w[PATCH PUT], drive: :action_update, events: %w[resource_action.updated] },
        'permission_forge/resource_actions#destroy' => { verbs: %w[DELETE], drive: :action_destroy,
                                                         events: %w[resource_action.destroyed] },
        'permission_forge/permission_set_rules#refresh' => { verbs: %w[POST], drive: :rule_refresh,
                                                             none: 're-renders the rule builder, saves nothing' },
        'permission_forge/permission_set_rules#toggle' => { verbs: %w[PATCH], drive: :rule_toggle, events: %w[permission_set_rule.updated] },
        'permission_forge/permission_set_rules#create' => { verbs: %w[POST], drive: :rule_create, events: %w[permission_set_rule.created] },
        'permission_forge/permission_set_rules#update' => { verbs: %w[PATCH PUT], drive: :rule_update,
                                                            events: %w[permission_set_rule.updated] },
        'permission_forge/permission_set_rules#destroy' => { verbs: %w[DELETE], drive: :rule_destroy,
                                                             events: %w[permission_set_rule.destroyed] },
        'permission_forge/permission_set_groups#create' => { verbs: %w[POST], drive: :group_create,
                                                             events: %w[permission_set_group.created] },
        'permission_forge/permission_set_groups#update' => { verbs: %w[PATCH PUT], drive: :group_update,
                                                             events: %w[permission_set_group.updated] },
        'permission_forge/permission_set_groups#destroy' => { verbs: %w[DELETE], drive: :group_destroy,
                                                              events: %w[permission_set.updated permission_set_group.destroyed] },
        'permission_forge/permission_set_groups#duplicate' => {
          verbs: %w[POST], drive: :group_duplicate,
          events: %w[permission_set.cloned permission_set.created permission_set_group.cloned permission_set_group.created
                     permission_set_rule.created resource.created resource_action.created resource_field.created]
        },
        'permission_forge/permission_set_groups#add_set' => { verbs: %w[POST], drive: :group_add_set, events: %w[permission_set.updated] },
        'permission_forge/permission_set_groups#remove_set' => { verbs: %w[DELETE], drive: :group_remove_set,
                                                                 events: %w[permission_set.updated] },
        'permission_forge/permission_set_group_users#create' => { verbs: %w[POST], drive: :member_add, events: %w[group_membership.added] },
        'permission_forge/permission_set_group_users#destroy' => { verbs: %w[DELETE], drive: :member_remove,
                                                                   events: %w[group_membership.removed] },

        # --- JSON API -----------------------------------------------------------------
        'permission_forge/api/permission_sets#create' => { verbs: %w[POST], drive: :api_set_create, events: %w[permission_set.created] },
        'permission_forge/api/permission_sets#update' => { verbs: %w[PATCH PUT], drive: :api_set_update, events: %w[permission_set.updated] },
        'permission_forge/api/permission_sets#destroy' => {
          verbs: %w[DELETE], drive: :api_set_destroy,
          events: %w[assignment.revoked permission_set.destroyed permission_set_rule.destroyed resource.destroyed
                     resource_action.destroyed resource_field.destroyed]
        },
        'permission_forge/api/permission_sets#clone' => {
          verbs: %w[POST], drive: :api_set_clone,
          events: %w[permission_set.cloned permission_set.created permission_set_rule.created resource.created
                     resource_action.created resource_field.created]
        },
        'permission_forge/api/resources#create' => { verbs: %w[POST], drive: :api_resource_create, events: %w[resource.created] },
        'permission_forge/api/resources#update' => { verbs: %w[PATCH PUT], drive: :api_resource_update, events: %w[resource.updated] },
        'permission_forge/api/resources#destroy' => {
          verbs: %w[DELETE], drive: :api_resource_destroy,
          events: %w[permission_set_rule.destroyed resource.destroyed resource_action.destroyed resource_field.destroyed]
        },
        'permission_forge/api/resources#generate_fields' => { verbs: %w[POST], drive: :api_generate_fields,
                                                              events: %w[resource_field.created] },
        'permission_forge/api/resource_fields#create' => { verbs: %w[POST], drive: :api_field_create, events: %w[resource_field.created] },
        'permission_forge/api/resource_fields#update' => { verbs: %w[PATCH PUT], drive: :api_field_update,
                                                           events: %w[resource_field.updated] },
        'permission_forge/api/resource_fields#destroy' => { verbs: %w[DELETE], drive: :api_field_destroy,
                                                            events: %w[resource_field.destroyed] },
        'permission_forge/api/resource_actions#create' => { verbs: %w[POST], drive: :api_action_create,
                                                            events: %w[resource_action.created] },
        'permission_forge/api/resource_actions#update' => { verbs: %w[PATCH PUT], drive: :api_action_update,
                                                            events: %w[resource_action.updated] },
        'permission_forge/api/resource_actions#destroy' => { verbs: %w[DELETE], drive: :api_action_destroy,
                                                             events: %w[resource_action.destroyed] },
        'permission_forge/api/permission_set_rules#create' => { verbs: %w[POST], drive: :api_rule_create,
                                                                events: %w[permission_set_rule.created] },
        'permission_forge/api/permission_set_rules#update' => { verbs: %w[PATCH PUT], drive: :api_rule_update,
                                                                events: %w[permission_set_rule.updated] },
        'permission_forge/api/permission_set_rules#destroy' => { verbs: %w[DELETE], drive: :api_rule_destroy,
                                                                 events: %w[permission_set_rule.destroyed] },
        'permission_forge/api/permission_set_users#create' => { verbs: %w[POST], drive: :api_assign, events: %w[assignment.granted] },
        'permission_forge/api/permission_set_users#bulk' => { verbs: %w[POST], drive: :api_bulk_assign, events: %w[assignment.granted] },
        'permission_forge/api/permission_set_users#destroy' => { verbs: %w[DELETE], drive: :api_revoke, events: %w[assignment.revoked] },
        'permission_forge/api/permission_set_groups#create' => { verbs: %w[POST], drive: :api_group_create,
                                                                 events: %w[permission_set_group.created] },
        'permission_forge/api/permission_set_groups#update' => { verbs: %w[PATCH PUT], drive: :api_group_update,
                                                                 events: %w[permission_set_group.updated] },
        'permission_forge/api/permission_set_groups#destroy' => { verbs: %w[DELETE], drive: :api_group_destroy,
                                                                  events: %w[permission_set.updated permission_set_group.destroyed] },
        'permission_forge/api/permission_set_groups#clone' => {
          verbs: %w[POST], drive: :api_group_clone,
          events: %w[permission_set.cloned permission_set.created permission_set_group.cloned permission_set_group.created
                     permission_set_rule.created resource.created resource_action.created resource_field.created]
        },
        'permission_forge/api/permission_set_group_users#create' => { verbs: %w[POST], drive: :api_member_add,
                                                                      events: %w[group_membership.added] },
        'permission_forge/api/permission_set_group_users#destroy' => { verbs: %w[DELETE], drive: :api_member_remove,
                                                                       events: %w[group_membership.removed] },
        'permission_forge/api/unmatched_routes#show' => { verbs: %w[POST PUT PATCH DELETE], drive: :api_unmatched,
                                                          none: 'no endpoint at this path and method: the JSON 404' }
      }.freeze

      API_PREFIX = 'permission_forge/api/'

      # The ways of acting each route is driven with.
      def self.modes_for(endpoint)
        endpoint.start_with?(API_PREFIX) ? %i[api_token] : %i[signed_in basic_auth]
      end

      def self.engine_write_routes = IntegrationSupport.engine_write_routes

      setup do
        @admin = create_user(name: ADMIN_NAME, email: 'ada@acme.test')
        @ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = create_user(name: 'Bo Berisha', email: 'bo@acme.test')
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true, edit_access: true)
        @email = create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true, mask_strategy: 'email')
        @action = create_resource_action(resource: @resource, name: 'export', label: 'Export', is_permitted: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers')
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
        @group = create_permission_set_group(name: 'Sales team')
      end

      # --- the table covers the engine --------------------------------------------------

      test 'every non-GET route of the engine is in the table with its verb' do
        unmapped = self.class.engine_write_routes.reject { |verb, _path, endpoint| ROUTES.dig(endpoint, :verbs)&.include?(verb) }

        assert_empty unmapped.map { |verb, path, endpoint| "#{verb} #{path} (#{endpoint})" },
                     "engine routes that can change something but say nothing about the audit log.\n#{HOW_TO_ADD}"
      end

      test 'every entry of the table is a route of the engine' do
        routed = self.class.engine_write_routes.group_by(&:last).transform_values { |rows| rows.map(&:first).sort }
        stale = ROUTES.reject { |endpoint, spec| routed[endpoint] == spec[:verbs].sort }

        assert_empty stale.keys, 'entries naming a route or verb the engine does not have (remove or correct them)'
      end

      test 'every entry names registered events or a reason, and a driver' do
        ROUTES.each do |endpoint, spec|
          assert spec[:events].present? ^ spec[:none].present?, "#{endpoint}: give events: or none:, not both"
          Array(spec[:events]).each { |name| assert Audit::EventCatalog.registered?(name), "#{endpoint}: #{name} is not catalogued" }
          assert respond_to?(:"drive_#{spec[:drive]}", true), "#{endpoint}: define drive_#{spec[:drive]}"
        end
      end

      # --- every route, driven ----------------------------------------------------------

      ROUTES.each do |endpoint, spec|
        modes_for(endpoint).each do |mode|
          test "#{endpoint} as #{mode}" do
            act_as(mode)
            send(:"drive_#{spec[:drive]}")
            events = @request_events || flunk("drive_#{spec[:drive]} made no request through admin_request / api_request")

            spec[:none] ? assert_no_change_recorded(endpoint, events) : assert_request_recorded(endpoint, spec, mode, events)
          end
        end
      end

      private

      def assert_no_change_recorded(endpoint, events)
        written = events.reject { |event| event.category == 'access' }
        assert_empty written.map(&:event), "#{endpoint} is listed as changing nothing audited"
        assert_tables_explained(endpoint)
      end

      def assert_request_recorded(endpoint, spec, mode, events)
        written = events.reject { |event| event.category == 'access' }
        assert_equal spec[:events].sort, recorded_names(written), "#{endpoint}: the events it writes (update ROUTES if intended)"
        written.each { |event| assert_request_context(endpoint, event, mode) }
        assert_equal 1, written.map(&:correlation_id).uniq.size, "#{endpoint}: one correlation id for the request"
        assert_tables_explained(endpoint)
      end

      def assert_request_context(endpoint, event, mode)
        label = "#{endpoint}: #{event.event} ##{event.id}"
        assert_equal expected_actor(mode), [event.actor_type, event.actor_id, event.actor_label], "#{label} actor"
        assert_equal endpoint.start_with?(API_PREFIX) ? 'api' : 'admin_ui', event.source, "#{label} source"
        assert_equal REASON, event.reason, "#{label} reason"
        assert event.request_id.present?, "#{label} request id"
      end

      # The reviewer / acknowledger column names the admin when the admin is
      # a record (signed in), and nobody under HTTP Basic.
      def assert_stamped_by_acting_admin(value)
        admin = PermissionForge.configuration.current_user_resolver.call
        admin ? assert_equal(admin.id, value) : assert_nil(value)
      end

      def set_path = "/permission_sets/#{@set.id}"
      def resource_path = "#{set_path}/resources/Customer"
      def api_set_path = "/permission_sets/#{@set.uuid}"
      def api_resource_path = "#{api_set_path}/resources/#{@resource.uuid}"

      # The last event named `name` about `record`.
      # The last event named `name` about `record`, with the Permission Set the record belongs to.
      def event_about(name, record, **attrs)
        event = assert_audit_event(name, record_type: record.class.base_class.name, record_id: record.id.to_s, **attrs)
        set_id = expected_set_id(record)
        set_id ? assert_equal(set_id, event.permission_set_id, "#{name}: permission_set_id") : assert_nil(event.permission_set_id)
        event
      end

      def expected_set_id(record)
        case record
        when PermissionSet then record.id
        when ResourceField, ResourceAction
          Resource.unscoped.find_by(id: record.resource_id)&.permission_set_id || (@resource.permission_set_id if record.resource_id == @resource.id)
        else record.try(:permission_set_id)
        end
      end

      # The whole row as it was before the request (`record` is the instance
      # the test arranged), bookkeeping aside.
      def assert_snapshot(name, record)
        event = event_about(name, record)
        assert_equal record.attributes.as_json.except(*TableLedger::BOOKKEEPING), event.data['snapshot'].except(*TableLedger::BOOKKEEPING),
                     "#{name} keeps a snapshot of the whole row"
        event
      end

      # `attribute` went from `from` to `to`, and nothing else is in `changes`.
      def assert_change(name, record, attribute, from, to)
        assert_changes(name, record, [attribute], attribute => [from, to])
      end

      # `changes` names exactly `columns`, with the given before/after pairs.
      def assert_changes(name, record, columns, pairs)
        event = event_about(name, record)
        pairs.each { |column, pair| assert_equal pair.as_json, event.data.dig('changes', column.to_s), "#{name}: #{column} before and after" }
        assert_equal columns.map(&:to_s).sort, event.data['changes'].keys.sort, "#{name}: the columns in changes"
        event
      end

      def assert_snapshots(*pairs)
        pairs.each_slice(2) { |name, record| assert_snapshot(name, record) }
      end

      # --- admin UI drivers ---------------------------------------------------------------

      # The catch-all under /api (POST /api/audit_events has no route): a
      # 404 in the envelope, nothing recorded or changed.
      def drive_api_unmatched
        @request_events = ledger_events do
          post "#{ROOT}/api/audit_events", params: { audit_event: { event: 'fake' }, reason: REASON }, headers: @auth_headers,
                                           as: :json
        end
        assert_response :not_found
        assert_equal 404, response.parsed_body.dig('error', 'status')
      end

      def drive_preferences
        admin_request(:patch, '/preferences', theme: 'dark')
      end

      def drive_cleanup
        @assignment.update_columns(expires_at: 1.day.ago)
        admin_request(:delete, '/maintenance/cleanup')
        assert_snapshot('assignment.revoked', @assignment)
        assert_audit_event('cleanup.expired_assignments', data: { 'removed' => 1, 'affected_user_ids' => [@ana.id.to_s] })
      end

      def drive_remove_all
        other = create_permission_set_user(user: @ana, permission_set: create_permission_set(name: 'Support'))
        admin_request(:delete, "/people/#{@ana.id}/remove_all")
        assert_snapshots('assignment.revoked', @assignment, 'assignment.revoked', other)
      end

      def drive_refresh_cache
        admin_request(:post, "/people/#{@ana.id}/refresh_cache")
      end

      def drive_withdraw_consent
        gated = create_permission_set(name: 'Newsletter', requires_session_flag: 'marketing_consent')
        assignment = create_permission_set_user(user: @ana, permission_set: gated)
        admin_request(:post, "/people/#{@ana.id}/consent", flag: 'marketing_consent')
        assert_snapshot('assignment.revoked', assignment)
        assert_audit_event('consent.withdrawn', subject_user_id: @ana.id.to_s,
                                                data: { 'consent_flag' => 'marketing_consent', 'revoked' => 1, 'set_uuids' => [gated.uuid] })
        assert PermissionSetUser.exists?(@assignment.id), 'an assignment not gated on the flag stays'
      end

      def drive_erase
        membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @ana)
        admin_request(:post, "/people/#{@ana.id}/erasure", confirmation: 'Ana Krasniqi')
        assert_snapshots('assignment.revoked', @assignment, 'group_membership.removed', membership)
        assert_audit_event('erasure.performed', subject_user_id: @ana.id.to_s, data: { 'set_uuids' => [@set.uuid], 'dry_run' => false })
      end

      def drive_keep
        admin_request(:post, "/assignments/#{@assignment.id}/keep")
        event = event_about('assignment.reviewed', @assignment, subject_user_id: @ana.id.to_s, data: { 'decision' => 'keep' })
        assert_nil event.data.dig('changes', 'reviewed_at', 0)
        assert_equal @assignment.reload.reviewed_at.as_json, event.data.dig('changes', 'reviewed_at', 1)
        assert_stamped_by_acting_admin(@assignment.reviewed_by_id)
      end

      def drive_restore
        admin_request(:post, '/assignments/restore', permission_set_id: @set.id, user_id: @bo.id)
        granted = PermissionSetUser.find_by!(user_id: @bo.id, permission_set_id: @set.id)
        assert_equal @set.uuid, event_about('assignment.granted', granted, subject_user_id: @bo.id.to_s).permission_set_uuid
      end

      def drive_undo
        rows = [create_permission_set(name: 'Support'), create_permission_set(name: 'Billing')].map do |set|
          create_permission_set_user(user: @bo, permission_set: set)
        end
        admin_request(:post, '/assignments/undo', ids: rows.map(&:id))
        assert_snapshots(*rows.flat_map { |row| ['assignment.revoked', row] })
      end

      def drive_assign
        other = create_permission_set(name: 'Support')
        admin_request(:post, '/assignments', user_id: @bo.id, set_ids: [@set.id, other.id], expiry: '1w')
        PermissionSetUser.where(user_id: @bo.id).find_each do |row|
          event = event_about('assignment.granted', row, subject_user_id: @bo.id.to_s)
          assert_equal row.expires_at.as_json, event.data.dig('snapshot', 'expires_at')
        end
      end

      def drive_change_expiry
        admin_request(:patch, "/assignments/#{@assignment.id}", expiry: 'extend30')
        # the row keeps the reason of its last change (T5)
        assert_changes('assignment.changed', @assignment, %i[expires_at reason], expires_at: [nil, @assignment.reload.expires_at],
                                                                                 reason: [nil, REASON])
      end

      def drive_revoke
        admin_request(:delete, "/assignments/#{@assignment.id}")
        assert_snapshot('assignment.revoked', @assignment)
      end

      def drive_set_review
        admin_request(:post, "#{set_path}/review", pf: { set: { description: 'Edited' } })
        assert_equal 'A test permission set', @set.reload.description
      end

      def drive_set_apply
        admin_request(:patch, "#{set_path}/apply", pf: { set: { description: 'Edited' }, resources: { @resource.id => { create_access: '1' } } })
        assert_change('permission_set.updated', @set, :description, 'A test permission set', 'Edited')
        assert_change('resource.updated', @resource, :create_access, false, true)
      end

      def drive_set_duplicate
        admin_request(:post, "#{set_path}/duplicate")
        copy = PermissionSet.find_by!(name: 'Sales rep (copy)')
        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, data: { 'source_uuid' => @set.uuid })
        assert_equal 'Sales rep (copy)', event_about('permission_set.created', copy).data.dig('snapshot', 'name')
      end

      def drive_switch_mode
        admin_request(:patch, "#{set_path}/switch_mode")
        assert_change('permission_set.updated', @set, :is_muting, false, true)
      end

      def drive_conditions
        admin_request(:patch, "#{set_path}/conditions", allowed_ips: '10.0.0.0/8')
        assert_change('permission_set.updated', @set, :allowed_ips, nil, '10.0.0.0/8')
      end

      def drive_set_create
        admin_request(:post, '/permission_sets', type: 'granting', name: 'Support desk')
        created = PermissionSet.find_by!(name: 'Support desk')
        assert_equal created.uuid, event_about('permission_set.created', created).data.dig('snapshot', 'uuid')
      end

      def drive_set_destroy
        admin_request(:delete, set_path)
        assert_snapshots('permission_set.destroyed', @set, 'resource.destroyed', @resource, 'resource_field.destroyed', @email,
                         'resource_action.destroyed', @action, 'permission_set_rule.destroyed', @rule, 'assignment.revoked', @assignment)
      end

      def drive_bulk_preview
        admin_request(:post, "#{set_path}/bulk_assignment/preview", identifiers: 'bo@acme.test')
        assert_not PermissionSetUser.exists?(user_id: @bo.id)
      end

      def drive_bulk_assign
        admin_request(:post, "#{set_path}/bulk_assignment", identifiers: 'bo@acme.test', expiry: 'never')
        event_about('assignment.granted', PermissionSetUser.find_by!(user_id: @bo.id), subject_user_id: @bo.id.to_s)
      end

      def drive_bulk_revoke
        admin_request(:delete, "#{set_path}/bulk_assignment/revoke", user_ids: [@ana.id])
        assert_snapshot('assignment.revoked', @assignment)
      end

      def drive_resource_review
        admin_request(:post, "#{resource_path}/review", pf: { resources: { @resource.id => { create_access: '1' } } })
        assert_not @resource.reload.create_access
      end

      def drive_resource_apply
        admin_request(:patch, "#{resource_path}/apply", pf: { resources: { @resource.id => { create_access: '1' } } })
        assert_change('resource.updated', @resource, :create_access, false, true)
      end

      def drive_sync
        gone = %w[gone_column also_gone].map { |name| create_resource_field(resource: @resource, name: name) }
        admin_request(:post, "#{resource_path}/sync", op: 'remove_missing')
        assert_snapshots(*gone.flat_map { |field| ['resource_field.destroyed', field] })
      end

      def drive_resource_create
        admin_request(:post, "#{set_path}/resources", model_name: 'Supplier', preset: 'read')
        supplier = @set.resources.find_by!(name: 'Supplier')
        assert_equal 'Supplier', event_about('resource.created', supplier).data.dig('snapshot', 'name')
        supplier.resource_fields.each { |field| event_about('resource_field.created', field) }
      end

      def drive_resource_destroy
        admin_request(:delete, resource_path)
        assert_snapshots('resource.destroyed', @resource, 'resource_field.destroyed', @email, 'resource_action.destroyed', @action,
                         'permission_set_rule.destroyed', @rule)
      end

      def drive_acknowledge
        admin_request(:post, "#{resource_path}/fields/email/acknowledge")
        event = event_about('field.sensitive_acknowledged', @email)
        assert_equal @email.reload.sensitive_acknowledged_at.as_json, event.data.dig('changes', 'sensitive_acknowledged_at', 1)
        assert_stamped_by_acting_admin(@email.sensitive_acknowledged_by_id)
      end

      def drive_apply_recommendation
        @email.update_columns(mask_access: false)
        admin_request(:post, "#{resource_path}/fields/email/apply_recommendation")
        assert_change('resource_field.updated', @email, :mask_access, false, true)
      end

      def drive_field_update
        admin_request(:patch, "#{resource_path}/fields/domain", field: { level: 'read', label: 'Web domain' })
        field = @resource.resource_fields.find_by!(name: 'domain')
        event_about('resource_field.created', field)
        assert_equal 'Web domain', event_about('resource_field.updated', field).data.dig('changes', 'label', 1)
      end

      def drive_action_create
        admin_request(:post, "#{resource_path}/actions", resource_action: { name: 'archive', label: 'Archive', is_permitted: '1' })
        created = @resource.resource_actions.find_by!(name: 'archive')
        assert_equal 'Archive', event_about('resource_action.created', created).data.dig('snapshot', 'label')
      end

      def drive_action_update
        admin_request(:patch, "#{resource_path}/actions/#{@action.id}", resource_action: { label: 'Export CSV' })
        assert_change('resource_action.updated', @action, :label, 'Export', 'Export CSV')
      end

      def drive_action_destroy
        admin_request(:delete, "#{resource_path}/actions/#{@action.id}")
        assert_snapshot('resource_action.destroyed', @action)
      end

      def drive_rule_refresh
        admin_request(:post, "#{resource_path}/rules/refresh", rule: { name: 'Draft', field_name: 'name', operator: 'equal' })
        assert_equal 1, @resource.permission_set_rules.count
      end

      def drive_rule_toggle
        admin_request(:patch, "#{resource_path}/rules/#{@rule.id}/toggle")
        assert_change('permission_set_rule.updated', @rule, :is_active, true, false)
      end

      def drive_rule_create
        admin_request(:post, "#{resource_path}/rules", rule: { name: 'Example only', field_name: 'domain', operator: 'equal',
                                                               value: 'example.com' })
        created = @resource.permission_set_rules.find_by!(name: 'Example only')
        assert_equal 'domain', event_about('permission_set_rule.created', created).data.dig('snapshot', 'field_name')
      end

      def drive_rule_update
        admin_request(:patch, "#{resource_path}/rules/#{@rule.id}", rule: { name: 'Renamed', field_name: 'name', operator: 'in',
                                                                            values_text: 'a,b' })
        assert_changes('permission_set_rule.updated', @rule, %i[name failure_message field_name field_value include_nulls operator],
                       name: ['Own customers', 'Renamed'], field_name: %w[supplier_id name], operator: %w[equal in],
                       field_value: ['current_user', 'a,b'])
      end

      def drive_rule_destroy
        admin_request(:delete, "#{resource_path}/rules/#{@rule.id}")
        assert_snapshot('permission_set_rule.destroyed', @rule)
      end

      def drive_group_create
        admin_request(:post, '/groups', name: 'Operations')
        group = PermissionSetGroup.find_by!(name: 'Operations')
        assert_equal 'Operations', event_about('permission_set_group.created', group).data.dig('snapshot', 'name')
      end

      def drive_group_update
        admin_request(:patch, "/groups/#{@group.id}", group: { name: 'Sales team EU' })
        assert_change('permission_set_group.updated', @group, :name, 'Sales team', 'Sales team EU')
      end

      def drive_group_destroy
        @set.update!(permission_set_group: @group)
        admin_request(:delete, "/groups/#{@group.id}")
        assert_snapshot('permission_set_group.destroyed', @group)
        assert_change('permission_set.updated', @set, :permission_set_group_id, @group.id, nil)
      end

      def drive_group_duplicate
        @set.update!(permission_set_group: @group)
        admin_request(:post, "/groups/#{@group.id}/duplicate")
        copy = PermissionSetGroup.find_by!(name: 'Sales team (copy)')
        assert_audit_event('permission_set_group.cloned', record_id: copy.id.to_s, data: { 'source_uuid' => @group.uuid })
        assert_audit_event('permission_set.cloned', permission_set_uuid: copy.permission_sets.first.uuid, data: { 'source_uuid' => @set.uuid })
      end

      def drive_group_add_set
        admin_request(:post, "/groups/#{@group.id}/add_set", permission_set_id: @set.id)
        assert_change('permission_set.updated', @set, :permission_set_group_id, nil, @group.id)
      end

      def drive_group_remove_set
        @set.update!(permission_set_group: @group)
        admin_request(:delete, "/groups/#{@group.id}/remove_set", permission_set_id: @set.id)
        assert_change('permission_set.updated', @set, :permission_set_group_id, @group.id, nil)
      end

      def drive_member_add
        admin_request(:post, "/groups/#{@group.id}/members", user_id: @bo.id)
        membership = PermissionSetGroupUser.find_by!(user_id: @bo.id)
        assert_equal @bo.id, event_about('group_membership.added', membership, subject_user_id: @bo.id.to_s).data.dig('snapshot', 'user_id')
      end

      def drive_member_remove
        membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @bo)
        admin_request(:delete, "/groups/#{@group.id}/members/#{membership.id}")
        assert_snapshot('group_membership.removed', membership)
      end

      # --- API drivers --------------------------------------------------------------------

      def drive_api_set_create
        api_request(:post, '/permission_sets', permission_set: { name: 'API set' })
        created = PermissionSet.find_by!(name: 'API set')
        assert_equal created.uuid, event_about('permission_set.created', created).data.dig('snapshot', 'uuid')
      end

      def drive_api_set_update
        api_request(:patch, api_set_path, permission_set: { description: 'Edited by API' })
        assert_change('permission_set.updated', @set, :description, 'A test permission set', 'Edited by API')
      end

      def drive_api_set_destroy
        api_request(:delete, api_set_path)
        assert_snapshots('permission_set.destroyed', @set, 'resource.destroyed', @resource, 'resource_field.destroyed', @email,
                         'resource_action.destroyed', @action, 'permission_set_rule.destroyed', @rule, 'assignment.revoked', @assignment)
      end

      def drive_api_set_clone
        api_request(:post, "#{api_set_path}/clone", name: 'API copy')
        copy = PermissionSet.find_by!(name: 'API copy')
        assert_audit_event('permission_set.cloned', record_uuid: copy.uuid, data: { 'source_uuid' => @set.uuid })
      end

      def drive_api_resource_create
        api_request(:post, "#{api_set_path}/resources", resource: { name: 'Supplier', read_access: true })
        supplier = @set.resources.find_by!(name: 'Supplier')
        assert_equal 'Supplier', event_about('resource.created', supplier).data.dig('snapshot', 'name')
      end

      def drive_api_resource_update
        api_request(:patch, api_resource_path, resource: { create_access: true })
        assert_change('resource.updated', @resource, :create_access, false, true)
      end

      def drive_api_resource_destroy
        api_request(:delete, api_resource_path)
        assert_snapshots('resource.destroyed', @resource, 'resource_field.destroyed', @email, 'resource_action.destroyed', @action,
                         'permission_set_rule.destroyed', @rule)
      end

      def drive_api_generate_fields
        api_request(:post, "#{api_resource_path}/generate_fields")
        generated = @resource.resource_fields.where.not(id: @email.id)
        assert_operator generated.count, :>, 1
        generated.each { |field| event_about('resource_field.created', field) }
      end

      def drive_api_field_create
        api_request(:post, "#{api_resource_path}/fields", resource_field: { name: 'domain', label: 'Domain', read_access: true })
        field = @resource.resource_fields.find_by!(name: 'domain')
        assert_equal 'Domain', event_about('resource_field.created', field).data.dig('snapshot', 'label')
      end

      def drive_api_field_update
        api_request(:patch, "#{api_resource_path}/fields/#{@email.uuid}", resource_field: { label: 'E-mail' })
        assert_change('resource_field.updated', @email, :label, 'Name', 'E-mail')
      end

      def drive_api_field_destroy
        api_request(:delete, "#{api_resource_path}/fields/#{@email.uuid}")
        assert_snapshot('resource_field.destroyed', @email)
      end

      def drive_api_action_create
        api_request(:post, "#{api_resource_path}/actions", resource_action: { name: 'archive', label: 'Archive' })
        created = @resource.resource_actions.find_by!(name: 'archive')
        assert_equal 'archive', event_about('resource_action.created', created).data.dig('snapshot', 'name')
      end

      def drive_api_action_update
        api_request(:patch, "#{api_resource_path}/actions/#{@action.uuid}", resource_action: { label: 'Export CSV' })
        assert_change('resource_action.updated', @action, :label, 'Export', 'Export CSV')
      end

      def drive_api_action_destroy
        api_request(:delete, "#{api_resource_path}/actions/#{@action.uuid}")
        assert_snapshot('resource_action.destroyed', @action)
      end

      def drive_api_rule_create
        api_request(:post, "#{api_resource_path}/rules",
                    permission_set_rule: { name: 'Example only', field_name: 'domain', operator: 'equal', field_value: 'example.com',
                                           failure_message: 'Not yours' })
        created = @resource.permission_set_rules.find_by!(name: 'Example only')
        assert_equal 'example.com', event_about('permission_set_rule.created', created).data.dig('snapshot', 'field_value')
      end

      def drive_api_rule_update
        api_request(:patch, "#{api_resource_path}/rules/#{@rule.uuid}", permission_set_rule: { name: 'Renamed' })
        assert_change('permission_set_rule.updated', @rule, :name, 'Own customers', 'Renamed')
      end

      def drive_api_rule_destroy
        api_request(:delete, "#{api_resource_path}/rules/#{@rule.uuid}")
        assert_snapshot('permission_set_rule.destroyed', @rule)
      end

      def drive_api_assign
        api_request(:post, "#{api_set_path}/users", user_id: @bo.id)
        event_about('assignment.granted', PermissionSetUser.find_by!(user_id: @bo.id), subject_user_id: @bo.id.to_s)
      end

      def drive_api_bulk_assign
        api_request(:post, "#{api_set_path}/users/bulk", user_ids: [@bo.id, @admin.id], bulk_action: 'assign')
        [@bo, @admin].each do |user|
          event_about('assignment.granted', PermissionSetUser.find_by!(user_id: user.id), subject_user_id: user.id.to_s)
        end
      end

      def drive_api_revoke
        api_request(:delete, "#{api_set_path}/users/#{@assignment.uuid}")
        assert_snapshot('assignment.revoked', @assignment)
      end

      def drive_api_group_create
        api_request(:post, '/permission_set_groups', permission_set_group: { name: 'Operations' })
        group = PermissionSetGroup.find_by!(name: 'Operations')
        assert_equal 'Operations', event_about('permission_set_group.created', group).data.dig('snapshot', 'name')
      end

      def drive_api_group_update
        api_request(:patch, "/permission_set_groups/#{@group.uuid}", permission_set_group: { name: 'Sales team EU' })
        assert_change('permission_set_group.updated', @group, :name, 'Sales team', 'Sales team EU')
      end

      def drive_api_group_destroy
        @set.update!(permission_set_group: @group)
        api_request(:delete, "/permission_set_groups/#{@group.uuid}")
        assert_snapshot('permission_set_group.destroyed', @group)
        assert_change('permission_set.updated', @set, :permission_set_group_id, @group.id, nil)
      end

      def drive_api_group_clone
        @set.update!(permission_set_group: @group)
        api_request(:post, "/permission_set_groups/#{@group.uuid}/clone", name: 'Sales API copy')
        copy = PermissionSetGroup.find_by!(name: 'Sales API copy')
        assert_audit_event('permission_set_group.cloned', record_uuid: copy.uuid, data: { 'source_uuid' => @group.uuid })
      end

      def drive_api_member_add
        api_request(:post, "/permission_set_groups/#{@group.uuid}/users", user_id: @bo.id)
        event_about('group_membership.added', PermissionSetGroupUser.find_by!(user_id: @bo.id), subject_user_id: @bo.id.to_s)
      end

      def drive_api_member_remove
        membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @bo)
        api_request(:delete, "/permission_set_groups/#{@group.uuid}/users/#{membership.uuid}")
        assert_snapshot('group_membership.removed', membership)
      end
    end
  end
end
