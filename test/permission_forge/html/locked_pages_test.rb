require_relative 'admin_test_case'

module PermissionForge
  module Html
    # "Locked" has one definition in views too (Admin::EditableLock): on every
    # page rendered for a locked record, every enabled control that leads to
    # a change — a link to a confirmation page, a form with an enabled
    # control, a button with its own formaction — is one EditableLock.permits?
    # allows for that record, or it is disabled. Six fixtures (a locked set,
    # resource, field, rule, group, and a locked Muting Permission Set, where
    # the direction flips); every mutating route is classified in
    # ROUTE_ACTIONS, so a new route must be classified before it may be
    # offered. The checker is a PORO (Offences) so the negative fixture can
    # prove the guard bites without changing a view.
    class LockedPagesTest < AdminTestCase
      # controller#action => [the record the route is on, the EditableLock action],
      # nil for a page that changes nothing, :always for a change a lock never refuses.
      ROUTE_ACTIONS = {
        'permission_sets#review' => %i[set edit], 'permission_sets#apply' => %i[set edit],
        'permission_sets#conditions' => %i[set edit], 'permission_sets#switch_mode' => %i[set edit],
        'permission_sets#confirm_switch_mode' => %i[set edit], 'permission_sets#duplicate' => %i[set duplicate],
        'permission_sets#destroy' => %i[set delete], 'permission_sets#confirm_destroy' => %i[set delete],
        'permission_sets#new' => nil, 'permission_sets#create' => nil,
        'resources#new' => %i[set add], 'resources#create' => %i[set add],
        'resources#review' => %i[resource edit], 'resources#apply' => %i[resource edit], 'resources#sync' => %i[resource edit],
        'resources#destroy' => %i[resource delete], 'resources#confirm_destroy' => %i[resource delete],
        'resource_fields#update' => %i[field edit], 'resource_fields#acknowledge' => %i[field acknowledge],
        'resource_fields#apply_recommendation' => %i[field apply_recommendation],
        'resource_actions#new' => %i[resource add], 'resource_actions#create' => %i[resource add],
        'resource_actions#update' => %i[action edit], 'resource_actions#destroy' => %i[action delete],
        'resource_actions#confirm_destroy' => %i[action delete],
        'permission_set_rules#new' => %i[resource add], 'permission_set_rules#create' => %i[resource add],
        'permission_set_rules#refresh' => %i[resource add], 'permission_set_rules#preview' => %i[resource add],
        'permission_set_rules#edit' => %i[rule edit],
        'permission_set_rules#update' => %i[rule edit], 'permission_set_rules#toggle' => %i[rule edit],
        'permission_set_rules#destroy' => %i[rule delete], 'permission_set_rules#confirm_destroy' => %i[rule delete],
        'assignments#new' => %i[set_param grant], 'assignments#create' => :always, # each set_ids[] input is checked on its own
        'assignments#update' => %i[assignment change_expiry], 'assignments#keep' => %i[assignment review],
        'assignments#destroy' => %i[assignment revoke], 'assignments#confirm_destroy' => %i[assignment revoke],
        'assignments#restore' => :always, 'assignments#undo' => :always,
        'bulk_assignments#new' => %i[set grant], 'bulk_assignments#preview' => %i[set grant], 'bulk_assignments#create' => %i[set grant],
        'bulk_assignments#confirm_revoke' => %i[set revoke], 'bulk_assignments#revoke' => %i[set revoke],
        'people#confirm_remove_all' => :always, 'people#remove_all' => :always, 'people#refresh_cache' => :always,
        'people#consent_preview' => :always, 'people#withdraw_consent' => :always, 'people#erasure_preview' => :always,
        'people#erase' => :always, 'preferences#update' => :always, 'maintenance#cleanup' => :always,
        'permission_set_groups#update' => %i[group edit], 'permission_set_groups#add_set' => %i[group edit],
        'permission_set_groups#remove_set' => %i[group edit], 'permission_set_groups#duplicate' => %i[group duplicate],
        'permission_set_groups#destroy' => %i[group delete], 'permission_set_groups#confirm_destroy' => %i[group delete],
        'permission_set_groups#create' => nil,
        'permission_set_group_users#create' => %i[group edit], 'permission_set_group_users#destroy' => %i[group edit]
      }.freeze
      # GET pages that change nothing: not classified, never an offence.
      READ_ONLY = %w[home#index people#index people#show permission_sets#index permission_sets#show resources#show
                     resource_fields#show resource_actions#show permission_set_groups#index permission_set_groups#show
                     audit_events#index audit_events#show audit_events#holdings settings#show field_lookups#show assets#show].freeze

      # A control the person can use: not disabled (also not inside a disabled
      # fieldset), not readonly, not one the form does not submit
      # (data-pf-untracked: the "Explain for" picker); a button with its own
      # formaction is checked against that target.
      ENABLED = 'button:not([disabled]):not([formaction]):not([type=button]), input:not([type=hidden]):not([disabled]):not([readonly]), ' \
                'select:not([disabled]), textarea:not([disabled]):not([readonly])'.freeze
      UNTRACKED = '[data-pf-untracked]'.freeze

      # Every control of one rendered page that offers a change the lock refuses.
      class Offences
        Offence = Struct.new(:path, :target, :why) do
          def to_s = "#{path}: #{target} (#{why})"
        end

        attr_reader :list

        # The record a route's params name, by kind (ROUTE_ACTIONS' first element).
        FINDERS = {
          set: ->(route, _query) { PermissionForge::PermissionSet.find(route[:permission_set_id] || route[:id]) },
          set_param: ->(_route, query) { query['permission_set_id'].presence && PermissionForge::PermissionSet.find(query['permission_set_id']) },
          resource: ->(route, _query) { resource_for(route) },
          field: ->(route, _query) { resource_for(route).resource_fields.find_by(name: route[:key]) || resource_for(route) },
          action: ->(route, _query) { resource_for(route).resource_actions.find(route[:id]) },
          rule: ->(route, _query) { resource_for(route).permission_set_rules.find(route[:id]) },
          assignment: ->(route, _query) { PermissionForge::PermissionSetUser.find(route[:id]) },
          group: ->(route, _query) { PermissionForge::PermissionSetGroup.find(route[:group_id] || route[:id]) }
        }.freeze

        def self.resource_for(route)
          set = PermissionForge::PermissionSet.find(route[:permission_set_id])
          set.resources.find_by!(name: route[:resource_model] || route[:model])
        end
        private_class_method :resource_for

        def initialize(path, body, root: AdminTestCase::ROOT, route_actions: ROUTE_ACTIONS)
          @path = path
          @doc = Nokogiri::HTML(body)
          @root = root
          @route_actions = route_actions
          @list = []
          check_forms
          check_links
          check_formaction_buttons
          check_set_pickers
        end

        private

        def check_forms
          @doc.css('form[action]').each do |form|
            control = form_controls(form).find { |node| usable?(node) }
            judge(form['action'], form_method(form), form, control) if control
          end
        end

        # The form's own controls (not those a `form=` attribute hands to
        # another form) and the ones elsewhere on the page that name it.
        def form_controls(form)
          own = form.css(ENABLED).reject { |node| node['form'] && node['form'] != form['id'] }
          joined = form['id'] ? @doc.css("[form='#{form['id']}']").select { |node| node.matches?(ENABLED) } : []
          own + joined
        end

        def form_method(form)
          form.at_css("input[name='_method']")&.[]('value') || form['method'] || 'get'
        end

        def check_links
          @doc.css('a[href]').each do |link|
            next if link['aria-disabled'] == 'true' || link['class'].to_s.split.include?('pf-btn--disabled')

            judge(link['href'], 'get', link)
          end
        end

        def check_formaction_buttons
          @doc.css('button[formaction]:not([disabled])').select { |button| usable?(button) }.each do |button|
            judge(button['formaction'], button['formmethod'] || 'post', button)
          end
        end

        def usable?(node)
          !node.matches?(UNTRACKED) && node.ancestors('fieldset[disabled]').empty?
        end

        # The Assign drawer: an enabled set checkbox offers a grant of that set.
        def check_set_pickers
          @doc.css("input[name='set_ids[]']:not([disabled])").each do |input|
            set = PermissionForge::PermissionSet.find(input['value'])
            offence("set_ids[] #{set.name}", 'grant refused') unless PermissionForge::Admin::EditableLock.permits?(set, :grant)
          end
        end

        def judge(href, method, node, control = node)
          route, query = recognize(href, method)
          return unless route

          site = site_of(route)
          return if READ_ONLY.include?(site)
          return offence(site, 'route not classified in ROUTE_ACTIONS') unless @route_actions.key?(site)

          verb = @route_actions.fetch(site)
          return if verb.nil? || verb == :always

          permitted = permitted?(verb, route, query, node)
          offence("#{method.upcase} #{href}", "#{verb.last} on the locked #{verb.first} is refused, offered by #{describe(control)}") unless permitted
        end

        def describe(node)
          attrs = %w[type name value formaction href].filter_map { |key| "#{key}=#{node[key]}" if node[key] }
          "<#{node.name} #{attrs.join(' ')}>"
        end

        def permitted?(verb, route, query, node)
          kind, action = verb
          record = record_for(kind, route, query)
          return true if record.nil?
          return expiry_permitted?(record, node) if action == :change_expiry

          PermissionForge::Admin::EditableLock.permits?(record, action)
        end

        # Only end dates the lock lets through are offered (EditableLock.expiry_choices).
        def expiry_permitted?(assignment, node)
          form = node.name == 'form' ? node : node.ancestors('form').first
          keys = form.css("select[name='expiry'] option, input[name='expiry']").map { |option| option['value'] }.compact_blank.uniq
          PermissionForge::Admin::EditableLock.expiry_choices(assignment, keys: keys) == keys
        end

        def site_of(route)
          "#{route[:controller].delete_prefix('permission_forge/')}##{route[:action]}"
        end

        def record_for(kind, route, query)
          FINDERS.fetch(kind) { raise ArgumentError, "unknown record kind #{kind.inspect}" }.call(route, query)
        end

        # [route params, query hash] for an engine path, nil for anything else (an external or host link).
        def recognize(href, method)
          uri = URI.parse(href.to_s)
          return unless uri.path.to_s.start_with?(@root)

          path = uri.path.delete_prefix(@root).presence || '/'
          [PermissionForge::Engine.routes.recognize_path(path, method: method.to_s.downcase), Rack::Utils.parse_nested_query(uri.query)]
        rescue ActionController::RoutingError, URI::InvalidURIError
          nil
        end

        def offence(target, why)
          @list << Offence.new(@path, target, why)
        end
      end

      setup do
        @action = create_resource_action(resource: @resource, name: 'export')
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own', field_name: 'name', field_value: 'x')
        @group = create_permission_set_group(name: 'Sales')
        @set.update!(permission_set_group: @group)
      end

      def set_pages(set, action: @action)
        base = "/permission_sets/#{set.id}"
        [base, "#{base}?tab=assignments", "#{base}?tab=conditions", "#{base}/resources/Customer",
         "#{base}/resources/Customer?tab=actions", "#{base}/resources/Customer?tab=rules",
         "#{base}/resources/Customer/fields/email", "#{base}/resources/Customer/fields/name",
         action && "#{base}/resources/Customer/actions/#{action.id}", '/permission_sets'].compact
      end

      def person_pages(user, remove: true)
        ['/', '/?cleanup=1', '/people', "/people/#{user.id}", "/people/#{user.id}/remove_all", "/assignments/new?user_id=#{user.id}",
         "/assignments/new?user_id=#{user.id}&permission_set_id=#{@set.id}", (remove ? "/assignments/#{@assignment.id}/remove" : nil)].compact
      end

      def offences_on(paths)
        paths.flat_map do |path|
          get pf(path)

          assert_response :success, path
          Offences.new(path, response.body).list
        end
      end

      test 'a locked Permission Set offers no change to what it holds, only duplicate, review and narrowing' do
        @set.update!(is_editable: false)
        @assignment.update!(expires_at: 3.days.from_now.end_of_day)

        assert_empty offences_on(set_pages(@set) + person_pages(@ana) + ['/field_lookup?resource=Customer&field=email']).map(&:to_s)
      end

      test 'a locked Resource under an editable set' do
        @resource.update!(is_editable: false)

        assert_empty offences_on(set_pages(@set) + ['/', "/people/#{@ana.id}"]).map(&:to_s)
      end

      test 'a locked field and a locked rule under an editable Resource' do
        @email.update!(is_editable: false)
        @rule.update!(is_editable: false)
        @rule.update_columns(field_name: 'stauts') # Home lists it under "Rules that match nothing"

        assert_empty offences_on(set_pages(@set) + ['/']).map(&:to_s)
      end

      test 'a locked Permission Set Group' do
        @group.update!(is_editable: false)
        create_permission_set_group(name: 'Other')

        assert_empty offences_on(['/groups', "/groups/#{@group.id}", "/permission_sets/#{@set.id}"]).map(&:to_s)
      end

      test 'a locked Muting Permission Set: holders may be added and kept longer, not removed or ended sooner' do
        muting = create_permission_set(name: 'No exports', is_muting: true, is_editable: false)
        create_resource(permission_set: muting, read_access: false, edit_access: true)
        held = create_permission_set_user(user: @bo, permission_set: muting, expires_at: 3.days.from_now.end_of_day)
        @assignment = held

        # The remove confirmation of a holder of a locked Muting Permission Set is refused (a redirect), not rendered.
        assert_empty offences_on(set_pages(muting, action: nil) + person_pages(@bo, remove: false)).map(&:to_s)
        get pf("/permission_sets/#{muting.id}?tab=assignments")
        clearing = "form[action='#{pf("/assignments/#{held.id}")}'] select[name=expiry] option[value=never]"
        assert_select clearing, count: 1, message: 'clearing the end date of a Muting Permission Set narrows access: offered'
        assert_select "a[href^='#{pf("/assignments/#{held.id}/remove")}']", count: 0, message: 'removing a holder widens access: not offered'
      end

      # --- the guard bites -------------------------------------------------------

      def review_form(button_attrs)
        %(<form action="#{pf("/permission_sets/#{@set.id}/review")}" method="post"><button type="submit" #{button_attrs}>Save</button></form>)
      end

      test 'negative fixture: an enabled control towards a refused change is an offence, a disabled one is not' do
        @set.update!(is_editable: false)

        assert_equal ["x: POST #{pf("/permission_sets/#{@set.id}/review")} (edit on the locked set is refused, offered by <button type=submit>)"],
                     Offences.new('x', review_form('')).list.map(&:to_s)
        assert_empty Offences.new('x', review_form('disabled')).list
        assert_empty Offences.new('x', %(<a href="#{pf("/permission_sets/#{@set.id}/delete")}" aria-disabled="true">Delete</a>)).list
        assert_equal 1, Offences.new('x', %(<a href="#{pf("/permission_sets/#{@set.id}/delete")}">Delete</a>)).list.size
      end

      test 'negative fixture: a mutating route that is not classified is an offence' do
        offences = Offences.new('x', review_form(''), route_actions: ROUTE_ACTIONS.except('permission_sets#review'))

        assert_equal ['route not classified in ROUTE_ACTIONS'], offences.list.map(&:why)
      end

      test 'every mutating engine route is classified' do
        mutating = PermissionForge::Engine.routes.routes.filter_map do |route|
          controller = route.defaults[:controller].to_s
          next if controller.start_with?('permission_forge/api') || controller.empty?

          verb = route.verb.to_s
          site = "#{controller.delete_prefix('permission_forge/')}##{route.defaults[:action]}"
          site unless verb == 'GET' && READ_ONLY.include?(site)
        end.uniq

        assert_empty mutating - ROUTE_ACTIONS.keys - READ_ONLY, 'classify the route in ROUTE_ACTIONS (or READ_ONLY for a page)'
      end
    end
  end
end
