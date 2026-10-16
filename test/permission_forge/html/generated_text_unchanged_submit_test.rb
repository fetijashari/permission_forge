require_relative 'admin_test_case'
require 'nokogiri'

module PermissionForge
  module Html
    # Review of the round-7 fixes (P1-1, P1-2, P2-2): a form pre-fills
    # generated text as blank (Admin::Prefill.text), and its save read that
    # blank as the admin's own value — an unchanged field drawer renamed
    # "Email" to "email", an unchanged action form blanked "Sync", a set
    # named 'Untitled Permission Set' could save no change on its page, a
    # rule or group under an install-default name had to be renamed first.
    #
    # One save-side definition (Admin::Prefill.posted): a blank posted over
    # stored generated text is no change. Each form is submitted here exactly
    # as the page renders it.
    class GeneratedTextUnchangedSubmitTest < AdminTestCase
      INSTALL_MESSAGE = 'You do not have permission to perform this action.'.freeze

      # The successful controls of `form` as a browser sends them: inputs
      # inside it or naming it (`form="id"`), checked boxes only, the
      # selected option, no buttons, nothing disabled.
      def form_pairs(doc, form)
        controls = form.css('input, select, textarea').to_a
        controls += doc.css(%([form="#{form['id']}"])).to_a if form['id']
        controls.uniq.filter_map { |control| control_pair(control) }
      end

      def control_pair(control)
        name = control['name']
        return if name.nil? || control.key?('disabled')

        case control.name
        when 'select' then [name, selected_value(control)]
        when 'textarea' then [name, control.text]
        else input_pair(control, name)
        end
      end

      def input_pair(control, name)
        type = control['type'].to_s.downcase
        return if %w[submit button image reset file].include?(type)
        return if %w[checkbox radio].include?(type) && !control.key?('checked')

        [name, control['value'].to_s]
      end

      def selected_value(select)
        option = select.at_css('option[selected]') || select.at_css('option')
        option ? (option['value'] || option.text).to_s : ''
      end

      # GETs `page`, then submits the form whose action is `action`, as
      # rendered, with `overrides` — to `to` when given (the set page's
      # "review" form, sent straight to "apply").
      def submit_as_rendered(page, action, to: nil, **overrides)
        get pf(page)
        assert_response :success
        doc = Nokogiri::HTML(response.body)
        form = doc.css('form').find { |node| node['action'] == pf(action) }
        assert form, "no form posting to #{action} on #{page}"
        pairs = form_pairs(doc, form).reject { |name, _| overrides.key?(name) } + overrides.to_a
        post to ? pf(to) : form['action'], params: URI.encode_www_form(pairs),
                             headers: { 'CONTENT_TYPE' => 'application/x-www-form-urlencoded' }
        assert_response :redirect
      end

      def assert_no_change(record, attribute, &)
        before = record.reload.public_send(attribute)
        before_events = AuditEvent.unscoped.pluck(:id)
        yield
        new_events = AuditEvent.unscoped.where.not(id: before_events).map { |event| [event.event, event.data] }
        assert_empty new_events, 'an unchanged submit writes no audit event'
        assert_equal before, record.reload.public_send(attribute)
      end

      def group(name)
        PermissionSetGroup.create!(name: 'Team', is_active: true, is_editable: true).tap { |g| g.update_columns(name: name) }
      end

      def field_page = "/permission_sets/#{@set.id}/resources/Customer/fields/email"
      def action_page(action) = "/permission_sets/#{@set.id}/resources/Customer/actions/#{action.id}"
      def rule_path(rule) = "/permission_sets/#{@set.id}/resources/Customer/rules/#{rule.id}"

      # ---- the field drawer ----------------------------------------------------

      test 'an unchanged field drawer keeps a generated label: no change, no event' do
        @email.update_columns(label: 'Email')
        assert_no_change(@email, :label) { submit_as_rendered(field_page, field_page) }
        assert_equal 'Email', @email.reload.label
        assert_not_includes flash[:notice].to_s, I18n.t('permission_forge.flash.fields.saved', count: 1, default: 'Saved 1 change')
      end

      test 'a label typed in the field drawer is saved; a blank one over an admin label is stored as the name' do
        @email.update_columns(label: 'Email')
        submit_as_rendered(field_page, field_page, 'field[label]' => 'Billing contact')
        assert_equal 'Billing contact', @email.reload.label

        submit_as_rendered(field_page, field_page, 'field[label]' => '')
        assert_equal 'email', @email.reload.label, 'clearing an admin-written label stores the name (documented)'
      end

      # ---- the action form -----------------------------------------------------

      test 'an unchanged action form keeps a generated label: no change, no event' do
        action = create_resource_action(resource: @resource, name: 'sync', label: 'Sync')
        assert_no_change(action, :label) { submit_as_rendered(action_page(action), action_page(action)) }
        assert_equal 'Sync', action.reload.label

        submit_as_rendered(action_page(action), action_page(action), 'resource_action[label]' => 'Sync to ERP')
        assert_equal 'Sync to ERP', action.reload.label
      end

      # ---- the set page ----------------------------------------------------------

      test 'a set under an install-default name: an unchanged submit changes nothing, a change saves' do
        @set.update_columns(name: 'Untitled Permission Set')
        set_page = "/permission_sets/#{@set.id}"
        apply = "#{set_page}/apply"

        get pf(set_page)
        assert_nil Nokogiri::HTML(response.body).at_css('#pf-set-name')['required'], 'a blank generated name is no missing name'

        submit_as_rendered(set_page, "#{set_page}/review")
        assert_redirected_to pf(set_page), 'the review has nothing to list'
        assert_no_change(@set, :name) { submit_as_rendered(set_page, "#{set_page}/review", '_method' => 'patch', to: apply) }
        assert_nil flash[:alert]
        assert_equal 'Untitled Permission Set', @set.reload.name

        patch pf(apply), params: { pf: { set: { name: '', description: '', is_active: '1' },
                                         resources: { @resource.id => { read_access: '1', create_access: '1', edit_access: '1',
                                                                        delete_access: '0' } } } }
        assert_nil flash[:alert]
        assert @resource.reload.create_access, 'a change on the page saves under a generated name'
        assert_equal 'Untitled Permission Set', @set.reload.name

        patch pf(apply), params: { pf: { set: { name: 'Operations' } } }
        assert_equal 'Operations', @set.reload.name
      end

      # ---- the rule builder ------------------------------------------------------

      test 'a rule under an install-default name and message: an unchanged builder save changes nothing' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own', field_name: 'domain',
                                          field_value: 'acme.test', include_nulls: false)
        rule.update_columns(name: 'Untitled Rule', failure_message: INSTALL_MESSAGE)

        assert_no_change(rule, :name) { submit_as_rendered("#{rule_path(rule)}/edit", rule_path(rule)) }
        assert_equal ['Untitled Rule', INSTALL_MESSAGE], [rule.reload.name, rule.failure_message]

        submit_as_rendered("#{rule_path(rule)}/edit", rule_path(rule), 'rule[value]' => 'other.test')
        assert_equal ['other.test', 'Untitled Rule', INSTALL_MESSAGE], [rule.reload.field_value, rule.name, rule.failure_message],
                     'another edit saves without a rename'

        submit_as_rendered("#{rule_path(rule)}/edit", rule_path(rule), 'rule[name]' => 'Own domain', 'rule[failure_message]' => 'Not yours')
        assert_equal ['Own domain', 'Not yours'], [rule.reload.name, rule.failure_message]
      end

      # ---- the group page --------------------------------------------------------

      test 'a group under an install-default name: an unchanged submit changes nothing, a change saves' do
        team = group('Untitled Permission Set Group')
        page = "/groups/#{team.id}"

        get pf(page)
        assert_nil Nokogiri::HTML(response.body).at_css('#pf-group-title')['required'], 'a blank generated name is no missing name'

        assert_no_change(team, :name) { submit_as_rendered(page, page) }
        submit_as_rendered(page, page, 'group[description]' => 'Front line')
        assert_nil flash[:alert]
        assert_equal ['Untitled Permission Set Group', 'Front line'], [team.reload.name, team.description]

        submit_as_rendered(page, page, 'group[name]' => 'Sales team')
        assert_equal 'Sales team', team.reload.name
        submit_as_rendered(page, page, 'group[name]' => '')
        assert_equal I18n.t('permission_forge.errors.admin.group_blank'), flash[:alert], 'an admin-written name still cannot be cleared'
      end
    end
  end
end
