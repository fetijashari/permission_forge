require_relative 'admin_test_case'
require_relative 'a11y_lint'

module PermissionForge
  module Html
    # A rule naming a column or relationship that is not there matches
    # nothing — the audit rates it High while people hold the set — and the
    # admin drew it as a normal sentence ("Only show Customers where Stauts
    # is active, or Stauts is empty"). Every place it is drawn says it
    # matches nothing, and why; Home lists it.
    class BrokenRulesAdminTest < AdminTestCase
      setup do
        @status = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Status',
                                             field_name: 'name', field_value: 'active', include_nulls: true)
        @status.update_columns(field_name: 'stauts')
        @via_owner = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Via owner',
                                                field_name: 'owner_id', field_value: 'current_user', include_nulls: false,
                                                join_type: 'joins', field_accessor_path: 'supplier')
        @via_owner.update_columns(field_accessor_path: 'ownr')
      end

      test 'Home lists each rule in effect that matches nothing, with why, linking to the rule' do
        get pf('/')

        assert_response :success
        assert_select '#pf-card-broken-rules', text: I18n.t('permission_forge.home.broken_rules_card.title')
        body = CGI.unescapeHTML(response.body)

        assert_includes body, 'Matches nothing: Stauts is not a column of Customer'
        assert_includes body, 'Matches nothing: Ownr is not a relationship of Customer'
        assert_includes body, '1 person has this set.'
        assert_select "a[href='#{pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")}']",
                      text: I18n.t('permission_forge.home.broken_rules_card.fix')
        assert_no_missing_translations
      end

      test 'Home leaves out a rule that is off, and opens the Rules tab for a locked set' do
        @via_owner.update_columns(is_active: false)
        @set.update_columns(is_editable: false)

        get pf('/')

        assert_select "section[aria-labelledby='pf-card-broken-rules'] .pf-card__row", count: 1
        assert_select "section[aria-labelledby='pf-card-broken-rules'] a", text: I18n.t('permission_forge.home.broken_rules_card.open')
        assert_select "section[aria-labelledby='pf-card-broken-rules'] a", text: I18n.t('permission_forge.home.broken_rules_card.fix'), count: 0
      end

      test 'the Rules tab says the rule matches nothing, and never "or empty"' do
        get pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules")

        assert_response :success
        assert_select '.pf-sentence .pf-badge--block', text: '⊘ Matches nothing', count: 2
        body = CGI.unescapeHTML(response.body)

        assert_includes body, 'Stauts is not a column of Customer'
        assert_includes body, 'stauts equal active'
        assert_includes body, 'ownr.owner_id equal current_user'
        assert_not_includes body, 'Stauts is empty'
        assert_not_includes body, 'Only show'
      end

      test 'the edit page of such a rule says so, as stored' do
        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")

        assert_response :success
        assert_select '.pf-banner--block', text: /This rule matches nothing/
        assert_select '.pf-banner--block', text: /Stauts is not a column of Customer/
        assert_select '.pf-banner--block', text: /Pick the field again/

        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@via_owner.id}/edit")

        assert_select '.pf-banner--block', text: /Ownr is not a relationship of Customer/
        assert_select '.pf-banner--block', text: /Choose the relationship again/
      end

      test 'a rule that works shows no such state' do
        @status.update_columns(field_name: 'name')
        @via_owner.update_columns(field_accessor_path: 'supplier')

        get pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules")
        assert_select '.pf-badge--block', count: 0
        assert_includes CGI.unescapeHTML(response.body), 'Name is empty'

        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")
        assert_select '.pf-banner--block', count: 0

        get pf('/')
        assert_select '#pf-card-broken-rules', count: 0
      end

      test "the person's effective access names the rule that matches nothing" do
        get pf("/people/#{@ana.id}?tab=effective")

        assert_response :success
        body = CGI.unescapeHTML(response.body)

        assert_includes body, '⊘ Matches nothing: Stauts is not a column of Customer'
        assert_includes body, 'Matches nothing: Ownr is not a relationship of Customer'
        assert_no_missing_translations
      end

      test 'every page drawing such a rule is clean and translated, in every locale' do
        paths = ['/', "/permission_sets/#{@set.id}/resources/Customer?tab=rules", "/permission_sets/#{@set.id}",
                 "/permission_sets/#{@set.id}/resources/Customer/rules/#{@via_owner.id}/edit", "/people/#{@ana.id}?tab=effective"]
        failures = %w[en sq mk].flat_map do |locale|
          paths.flat_map do |path|
            get pf(path), params: { locale: locale }
            assert_response :success
            assert_no_missing_translations
            A11yLint.new(response.body).problems.map { |problem| "#{locale} #{path}: #{problem}" }
          end
        end

        assert_empty failures, failures.join("\n")
        get pf('/'), params: { locale: 'sq' }
        assert_includes CGI.unescapeHTML(response.body), 'Nuk përputhet me asgjë'
      end

      test 'the Permission Set page summarises the rule that matches nothing first' do
        @status.update_columns(field_name: 'name')

        get pf("/permission_sets/#{@set.id}")

        assert_response :success
        assert_includes CGI.unescapeHTML(response.body), '⊘ Matches nothing: Ownr is not a relationship of Customer'
      end
    end
  end
end
