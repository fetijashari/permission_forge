require_relative 'admin_test_case'
require_relative 'a11y_lint'
require_relative '../rule_path_models'
require_relative '../../support/rule_problem_fixtures'

module PermissionForge
  module Html
    # A rule naming a column or relationship that is not there matches
    # nothing — the audit rates it High while people hold the set — and the
    # admin drew it as a normal sentence ("Only show Customers where Stauts
    # is active, or Stauts is empty"). Every place it is drawn says it
    # matches nothing, and why; Home lists it. Every kind of the taxonomy
    # (Operators::RuleProblem::KINDS) is drawn, in every locale.
    class BrokenRulesAdminTest < AdminTestCase
      include RuleProblemFixtures

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

        assert_includes body, 'Matches nothing: <code class="pf-mono-key">stauts</code> is not a column of Customer'
        assert_includes body, 'Matches nothing: <code class="pf-mono-key">ownr</code> is not a relationship of Customer'
        assert_includes body, '1 person has this set.'
        assert_select "a[href='#{pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")}']",
                      text: I18n.t('permission_forge.home.broken_rules_card.fix')
        assert_no_missing_translations
      end

      # Review round 5: why a relationship cannot be followed, by cause; an
      # empty step of the path never draws a blank name.
      test 'Home says why a relationship cannot be followed, and names an empty step of the path' do
        require_relative '../rule_path_models'
        path_resource = create_resource(permission_set: @set, name: 'PfRulePathRecord', read_access: true)
        polymorphic = create_permission_set_rule(permission_set: @set, resource: path_resource, name: 'Subject',
                                                 field_name: 'id', field_value: '1', join_type: 'joins',
                                                 field_accessor_path: 'parent', include_nulls: false)
        polymorphic.update_columns(field_accessor_path: 'subject')
        @via_owner.update_columns(field_accessor_path: 'supplier..owner')

        get pf('/')
        body = CGI.unescapeHTML(response.body)

        assert_includes body, 'Matches nothing: subject is a polymorphic relationship of PfRulePathRecord: a rule cannot follow it'
        assert_includes body, 'Matches nothing: The relationship path has an empty step (two dots in a row, or a dot at the start)'
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

        assert_includes body, '<code class="pf-mono-key">stauts</code> is not a column of Customer'
        assert_includes body, 'stauts equal active'
        assert_includes body, 'ownr.owner_id equal current_user'
        assert_not_includes body, 'Stauts is empty'
        assert_not_includes body, 'Only show'
      end

      test 'the edit page of such a rule says so, as stored' do
        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")

        assert_response :success
        assert_select '.pf-banner--block', text: /This rule matches nothing/
        assert_select '.pf-banner--block', text: /stauts is not a column of Customer/
        assert_select '.pf-banner--block', text: /Pick the field again/

        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@via_owner.id}/edit")

        assert_select '.pf-banner--block', text: /ownr is not a relationship of Customer/
        assert_select '.pf-banner--block', text: /Choose the relationship again/
      end

      test 'a rule that works shows no such state' do
        @status.update_columns(field_name: 'name')
        @via_owner.update_columns(field_accessor_path: 'supplier')

        get pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules")
        assert_select '.pf-badge--block', count: 0
        assert_includes CGI.unescapeHTML(response.body), 'name is empty', 'the column name as stored: the host has no translation'

        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{@status.id}/edit")
        assert_select '.pf-banner--block', count: 0

        get pf('/')
        assert_select '#pf-card-broken-rules', count: 0
      end

      test "the person's effective access names the rule that matches nothing" do
        get pf("/people/#{@ana.id}?tab=effective")

        assert_response :success
        body = CGI.unescapeHTML(response.body)

        assert_includes body, '⊘ Matches nothing: <code class="pf-mono-key">stauts</code> is not a column of Customer'
        assert_includes body, 'Matches nothing: <code class="pf-mono-key">ownr</code> is not a relationship of Customer'
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
        assert_includes CGI.unescapeHTML(response.body), '⊘ Matches nothing: <code class="pf-mono-key">ownr</code> is not a relationship of Customer'
      end

      # --- every kind of the taxonomy -------------------------------------------

      EXPECTED_LINES = {
        missing_column: 'Matches nothing: <code class="pf-mono-key">stauts</code> is not a column of Customer',
        unknown_association: 'Matches nothing: <code class="pf-mono-key">ownr</code> is not a relationship of Customer',
        unjoinable_association: 'Matches nothing: subject is a polymorphic relationship of PfRulePathRecord: a rule cannot follow it',
        unknown_operator: 'Matches nothing: <code class="pf-mono-key">regex</code> is not a condition this version knows',
        unknown_join_type: 'Matches nothing: <code class="pf-mono-key">inner</code> is not a way of joining this version knows',
        unknown_table: 'Matches nothing: <code class="pf-mono-key">nosuch</code> is not a table of this database',
        unusable_value: 'Matches nothing: <code class="pf-mono-key">5_id</code> is not a value supplier_id of Customer can hold'
      }.freeze

      test 'Home, the Rules tab and the edit page say why, for every kind, in every locale' do
        [@status, @via_owner].each(&:destroy!)
        rules = every_kind
        assert_equal Operators::RuleProblem::KINDS.sort, EXPECTED_LINES.keys.sort, 'an expected line per kind'

        get pf('/')
        body = CGI.unescapeHTML(response.body)
        EXPECTED_LINES.each { |kind, line| assert_includes body, line, kind }
        assert_select "section[aria-labelledby='pf-card-broken-rules'] .pf-card__row", count: rules.size

        failures = %w[en sq mk].flat_map do |locale|
          rules.flat_map do |kind, rule|
            paths = ['/', "/permission_sets/#{@set.id}/resources/#{rule.resource.name}?tab=rules",
                     "/permission_sets/#{@set.id}/resources/#{rule.resource.name}/rules/#{rule.id}/edit"]
            paths.flat_map do |path|
              get pf(path), params: { locale: locale }
              assert_response :success, "#{locale} #{kind} #{path}"
              assert_no_missing_translations
              problems = A11yLint.new(response.body).problems.map { |problem| "#{locale} #{kind} #{path}: #{problem}" }
              problems << "#{locale} #{kind} #{path}: no matches-nothing state" unless response.body.include?('⊘')
              problems
            end
          end
        end

        assert_empty failures, failures.join("\n")
      end

      test 'the edit page of a rule with an unknown condition keeps it as stored and says the rule matches nothing' do
        rule = broken_rule(:unknown_operator, permission_set: @set, resource: @resource)

        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{rule.id}/edit")

        assert_response :success
        assert_select '.pf-banner--block', text: /This rule matches nothing/
        assert_select '.pf-banner--block', text: /regex is not a condition this version knows/
        assert_select '.pf-banner--block', text: /Pick the condition again/
        assert_equal 'regex', PermissionForge::Admin::RuleForm.new(resource: @resource, rule: rule).operator, 'kept, not rewritten'
      end

      test 'a posted condition that is not one is refused, never rewritten to "is"' do
        post pf("/permission_sets/#{@set.id}/resources/Customer/rules"),
             params: { rule: { name: 'Crafted', field_name: 'name', operator: 'regex', value: 'x' } }

        assert_response :unprocessable_entity
        assert_select '.pf-error', text: I18n.t('permission_forge.permission_set_rules.builder.errors.operator')
        assert_not PermissionForge::PermissionSetRule.exists?(name: 'Crafted')
      end

      # --- a mask strategy this app does not know -------------------------------

      test 'a field whose mask strategy this app does not know is drawn masked, with a badge, never a 500' do
        @email.update_columns(mask_strategy: 'gone')

        get pf("/permission_sets/#{@set.id}/resources/Customer?tab=fields")

        assert_response :success
        assert_includes response.body, '********'

        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")

        assert_response :success
        assert_select '.pf-badge', text: I18n.t('permission_forge.ui.badges.unknown_mask_strategy')
        # Field test round 6 (d-api 33–35): the select showed nothing selected, and saving the drawer after
        # changing only the label rewrote the strategy to full. The stored name is offered as it is, selected.
        assert_select '#pf-fd-strategy option[selected]', count: 1
        assert_select '#pf-fd-strategy option[selected][value=gone]', text: /gone .*unknown/

        %w[sq mk].each do |locale|
          get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"), params: { locale: locale }
          assert_response :success
          assert_no_missing_translations
        end
        assert_empty A11yLint.new(response.body).problems
      end

      test 'saving the drawer with another change keeps a strategy this app does not know; picking one changes it' do
        @email.update_columns(mask_strategy: 'gone')
        path = pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")

        patch path, params: { field: { level: 'masked', mask_strategy: 'gone', label: 'E-mail' } }

        assert_response :redirect
        assert_equal %w[gone E-mail], [@email.reload.mask_strategy, @email.label]

        patch path, params: { field: { level: 'masked', mask_strategy: 'email', label: 'E-mail' } }

        assert_response :redirect
        assert_equal 'email', @email.reload.mask_strategy

        # A row whose stored name is not one is still refused when another unknown one is posted.
        patch path, params: { field: { level: 'masked', mask_strategy: 'nope', label: 'E-mail' } }

        assert_equal 'email', @email.reload.mask_strategy
      end

      private

      # One rule per kind of RuleProblem::KINDS, on a Resource of its model.
      def every_kind
        resources = { 'Customer' => @resource }
        FIXTURES.each_key.to_h do |kind|
          name = fixture_model_name(kind)
          resource = resources[name] ||= create_resource(permission_set: @set, name: name, read_access: true)
          [kind, broken_rule(kind, permission_set: @set, resource: resource)]
        end
      end
    end
  end
end
