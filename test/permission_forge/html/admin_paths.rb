# frozen_string_literal: true

module PermissionForge
  module Html
    # The one list of admin screens: every page, drawer, dialog and audit page
    # of the sample data, the locked and broken variants, and the requests the
    # admin answers with a re-rendered form (422). Built from the ids of the
    # sample data, so the whole-UI tests (AdminPagePaths, on the suite's
    # fixtures) and the browser probe (test/support/preview_app.rb, on its
    # seeds) walk the same screens. admin_page_paths_test.rb checks that every
    # GET route of the engine and every 422 render site is on it.
    class AdminPaths
      # A request and the answer the admin gives it. `site` is the controller
      # and the method that renders the answer (`controller#method`, as
      # admin_page_paths_test.rb scans them); `status` the final status (after
      # a redirect); `renders` false for a bodiless answer (an export's 422).
      Request = Struct.new(:site, :verb, :path, :params, :status, :renders, keyword_init: true) do
        def renders? = renders != false

        def to_h = super.compact
      end

      attr_reader :ids

      # @param ids [Hash] :ana, :assignment, :set, :muting, :locked, :group,
      #   :action, :rule, :broken (record ids); :updated_event,
      #   :destroyed_event (event uuids, nil when none was recorded)
      def initialize(**ids)
        @ids = ids
      end

      def paths
        people_paths + permission_set_paths + locked_paths + resource_paths + other_paths + audit_paths
      end

      # The 422 answers: one entry per render site, with the params that reach it.
      def error_states
        requests.select { |request| request.status == 422 }
      end

      # Changes that redirect to a page with a toast (the sticky layers after a POST).
      def flows
        requests.select { |request| request.status == 200 }
      end

      private

      def id(key) = ids.fetch(key)
      def person = "/people/#{id(:ana)}"
      def set_path = "/permission_sets/#{id(:set)}"
      def resource_base = "#{set_path}/resources/Customer"
      def locked_base = "/permission_sets/#{id(:locked)}"

      def people_paths
        [
          '/', '/?cleanup=1', '/?privacy=all', '/people', '/people?filter=ending', person,
          "#{person}?tab=effective&why=Customer.read_access", "#{person}?tab=audit",
          "#{person}/remove_all", "#{person}/consent", "#{person}/erasure",
          '/assignments/new', "/assignments/new?user_id=#{id(:ana)}", "/assignments/#{id(:assignment)}/remove"
        ]
      end

      def permission_set_paths
        [
          '/permission_sets', '/permission_sets?filter=muting', '/permission_sets/new', set_path,
          "#{set_path}?tab=assignments", "#{set_path}?tab=conditions", "#{set_path}?tab=audit",
          "#{set_path}/delete", "#{set_path}/switch_mode", "/permission_sets/#{id(:muting)}",
          "#{set_path}/bulk_assignment/new", "#{set_path}/bulk_assignment/revoke?user_ids[]=#{id(:ana)}",
          "#{set_path}/resources/new"
        ]
      end

      # A locked set (read-only inputs, no savebar) down to its field and rules,
      # and the edit page of a rule whose column is misspelled.
      def locked_paths
        [
          locked_base, "#{locked_base}?tab=assignments", "#{locked_base}/resources/Customer",
          "#{locked_base}/resources/Customer?tab=rules", "#{locked_base}/resources/Customer/fields/name",
          "#{resource_base}/rules/#{id(:broken)}/edit"
        ]
      end

      def resource_paths
        base = resource_base
        [
          base, "#{base}?tab=actions", "#{base}?tab=rules", "#{base}/delete", "#{base}/fields/email",
          "#{base}/fields/domain?explain_user_id=#{id(:ana)}",
          "#{base}/actions/new", "#{base}/actions/#{id(:action)}", "#{base}/actions/#{id(:action)}/delete",
          "#{base}/rules/new", "#{base}/rules/#{id(:rule)}/edit", "#{base}/rules/#{id(:rule)}/delete"
        ]
      end

      def other_paths
        [
          '/field_lookup', '/field_lookup?resource=Customer&field=email', '/groups', '/groups?new=1',
          "/groups/#{id(:group)}", "/groups/#{id(:group)}/delete", '/settings', '/settings?q=cache&changed=1'
        ]
      end

      # The audit log, filtered, one event of each shape (an update's
      # before/after, a destroy's snapshot), and page 2.
      def audit_paths
        ana = id(:ana)
        [
          '/audit', "/audit?event=assignment.granted&from=2020-01-01&permission_set=#{id(:set)}", '/audit?page=2',
          "/audit?actor_type=user&actor_id=#{ana}&subject_user_id=#{ana}&correlation_id=x&record_type=PermissionForge::PermissionSet&record_id=1",
          *%i[updated_event destroyed_event].filter_map { |key| ids[key] && "/audit/#{ids[key]}" }
        ]
      end

      def rule_params
        { rule: { name: '', field_name: 'name', operator: 'equal', value: 'x' } }
      end

      def requests # rubocop:disable Metrics/MethodLength
        [
          Request.new(site: 'assignments#create', verb: :post, path: '/assignments',
                      params: { expiry: 'custom', custom_date: '' }, status: 422),
          Request.new(site: 'audit_events#invalid_filters', verb: :get, path: '/audit', params: { from: '2026-02-30' }, status: 422),
          Request.new(site: 'audit_events#invalid_filters', verb: :get, path: '/audit.csv', params: { actor_id: %w[1 2] },
                      status: 422, renders: false),
          Request.new(site: 'bulk_assignments#create', verb: :post, path: "#{set_path}/bulk_assignment",
                      params: { identifiers: 'nobody@x.test' }, status: 422),
          Request.new(site: 'people#erase', verb: :post, path: "#{person}/erasure", params: { confirmation: 'someone else' }, status: 422),
          Request.new(site: 'permission_set_groups#render_blank_name', verb: :post, path: '/groups', params: { name: '' }, status: 422),
          Request.new(site: 'permission_set_rules#save_rule', verb: :post, path: "#{resource_base}/rules", params: rule_params, status: 422),
          Request.new(site: 'permission_set_rules#save_rule', verb: :patch, path: "#{resource_base}/rules/#{id(:rule)}",
                      params: rule_params, status: 422),
          Request.new(site: 'permission_sets#conditions', verb: :patch, path: "#{set_path}/conditions",
                      params: { allowed_ips: "10.0.0.0/8\n10.0.0.300" }, status: 422),
          Request.new(site: 'permission_sets#create', verb: :post, path: '/permission_sets', params: { type: 'granting', name: '' }, status: 422),
          Request.new(site: 'resource_actions#render_invalid', verb: :post, path: "#{resource_base}/actions",
                      params: { resource_action: { name: 'Bad Key!' } }, status: 422),
          Request.new(site: 'resources#create', verb: :post, path: "#{set_path}/resources",
                      params: { model_name: 'Customer', preset: 'read' }, status: 422),
          Request.new(site: 'people#refresh_cache', verb: :post, path: "#{person}/refresh_cache", params: {}, status: 200)
        ]
      end
    end
  end
end
