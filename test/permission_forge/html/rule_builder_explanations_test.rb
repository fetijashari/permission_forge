require_relative 'admin_test_case'
require_relative '../rule_path_models'
require_relative '../../support/rule_problem_fixtures'

module PermissionForge
  module Html
    # EX in the rule builder: what explains a rule comes from what decides it.
    # The preview is the sentence the saved rule shows (SentencesHelper,
    # fetched from the server by pf_admin.js), and a rule that matches nothing
    # is told the fix for its own kind of problem (Operators::RuleProblem),
    # saying the stored name once.
    class RuleBuilderExplanationsTest < AdminTestCase
      include RuleProblemFixtures

      # Builder params => what the saved rule's sentence must equal.
      PREVIEW_CASES = [
        { field_name: 'name', operator: 'equal', value: 'Acme' },
        { field_name: 'supplier_id', operator: 'equal', current_user: '1', include_nulls: '1' },
        { field_name: 'name', operator: 'in', values_text: "Acme\nGlobex" },
        { field_name: 'supplier_id', operator: 'between', value_from: '1', value_to: '9' },
        { field_name: 'domain', operator: 'is_null' },
        { path: ['supplier'], field_name: 'owner_id', operator: 'equal', current_user: '1' }
      ].freeze

      def rules_base = "/permission_sets/#{@set.id}/resources/Customer/rules"

      def sentence_text(html, selector = '.pf-sentence')
        Nokogiri::HTML(html).css(selector).map { |node| node.text.squish }
      end

      test 'the preview is the sentence the saved rule shows, one string from one helper' do
        PREVIEW_CASES.each_with_index do |params, index|
          rule = params.merge(name: "Preview #{index}", failure_message: 'No')
          get pf("#{rules_base}/preview"), params: { rule: rule }, headers: { 'X-PF-Fragment' => '1' }
          assert_response :success
          preview = sentence_text(response.body)

          post pf(rules_base), params: { rule: rule }
          assert_response :redirect, "#{params}: saved"
          saved = PermissionForge::PermissionSetRule.find_by!(name: "Preview #{index}")
          get pf("#{rules_base}/#{saved.id}/delete")

          assert_equal 1, preview.size, "#{params}: one sentence in the preview"
          assert_equal sentence_text(response.body), preview, "#{params}: the preview and the saved rule's sentence"
        end
      end

      test 'the preview fragment is the panel content alone; without JS it is a page of its own' do
        get pf("#{rules_base}/preview"), params: { rule: { field_name: 'name', operator: 'equal', value: 'Acme' } },
                                         headers: { 'X-PF-Fragment' => '1' }
        assert_response :success
        assert_no_match(/<html|pf-sidebar/, response.body)

        get pf("#{rules_base}/preview"), params: { rule: { field_name: 'name', operator: 'equal', value: 'Acme' } }
        assert_response :success
        assert_select 'h1'
        assert_select '.pf-sentence', count: 1
        assert_no_missing_translations

        get pf("#{rules_base}/preview")
        assert_response :success, 'no rule yet: the empty preview, never an error'
        assert_includes response.body, I18n.t('permission_forge.permission_set_rules.builder.preview_empty')
      end

      test 'the builder renders the preview in place and tells the script where to fetch it' do
        get pf("#{rules_base}/new")

        assert_select "[data-pf-rule-preview='#{pf("#{rules_base}/preview")}'][aria-live=polite]"
      end

      # --- a rule that matches nothing ------------------------------------------

      # RuleProblem kind => the fix the banner names.
      FIXES = {
        missing_column: 'field', unknown_table: 'field', unusable_value: 'value', unknown_operator: 'operator',
        unknown_join_type: 'join', unknown_association: 'path', unjoinable_association: 'path'
      }.freeze

      test 'the banner names the fix for each kind of problem, in every locale' do
        assert_equal Operators::RuleProblem::KINDS.sort, FIXES.keys.sort, 'a fix per kind'
        assert_equal FIXES, Operators::RuleProblem::REMEDIES.transform_values(&:to_s), 'RuleProblem#remedy is the one definition'
        failures = FIXES.flat_map do |kind, fix|
          resource = fixture_model_name(kind) == 'Customer' ? @resource : create_resource(permission_set: @set, name: fixture_model_name(kind))
          rule = broken_rule(kind, permission_set: @set, resource: resource)
          PermissionForge::BUNDLED_LOCALES.filter_map do |locale|
            get pf("/permission_sets/#{@set.id}/resources/#{resource.name}/rules/#{rule.id}/edit"), params: { locale: locale }
            banner = Nokogiri::HTML(response.body).at_css('.pf-banner--block')&.text.to_s.squish
            expected = I18n.t("permission_forge.permission_set_rules.builder.problem_fixes.#{fix}", locale: locale)
            "#{locale} #{kind}: #{banner.inspect} does not say #{expected.inspect}" unless banner.include?(expected)
          end
        end

        assert_empty failures, failures.join("\n")
      end

      # Field test round 6 (B #63): "stauts is not a column of Customer · stauts".
      test 'the banner says the stored name once' do
        rule = broken_rule(:missing_column, permission_set: @set, resource: @resource)

        get pf("#{rules_base}/#{rule.id}/edit")

        banner = Nokogiri::HTML(response.body).at_css('.pf-banner--block').text
        assert_equal 1, banner.scan('stauts').size, banner.squish

        via = broken_rule(:missing_column, permission_set: @set, resource: @resource, join_type: 'joins', field_accessor_path: 'supplier')
        get pf("#{rules_base}/#{via.id}/edit")

        assert_includes Nokogiri::HTML(response.body).at_css('.pf-banner--block').text, 'supplier.stauts',
                        'the written path is kept where it says more than the name'
      end
    end
  end
end
