require_relative 'admin_test_case'
require_relative '../secret_column_models'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 7 (B#48b): what the admin says about a stored rule
    # beside its sentence is one list, Admin::RuleNotes — why it matches
    # nothing (Operators::RuleProblem) first, then that it compares a secret
    # column (PermissionForge::SecretColumns: refused for a new rule, this
    # one still evaluates) — drawn by the builder's banner, the preview and
    # the Rules tab's row badge. Home's "Fix rule" for a secret rule used to
    # open a builder with no banner and a preview that read as fine.
    # The builder offers no column holding ciphertext (`encrypts`), as it
    # offers no secret column — except the one a stored rule names.
    class RuleNotesTest < AdminTestCase
      setup do
        @vault = create_permission_set(name: 'Vault')
        @secrets = create_resource(permission_set: @vault, name: 'PfSecretRecord', read_access: true)
        @secret = create_permission_set_rule(permission_set: @vault, resource: @secrets, name: 'Token rule', field_name: 'label',
                                             operator: 'is_not_null', field_value: nil)
        @secret.update_columns(field_name: 'api_token')
      end

      def page(path, **params)
        get pf(path), params: params
        assert_response :success, path
        Nokogiri::HTML(response.body)
      end

      test 'the notes of a rule: why it matches nothing first, then a secret column' do
        assert_equal [:secret_column], Admin::RuleNotes.for(@secret).map(&:kind)
        @secret.update_columns(field_accessor_path: 'nosuch', join_type: 'joins')
        assert_equal %i[matches_nothing secret_column], Admin::RuleNotes.for(@secret.reload).map(&:kind)
        assert_kind_of Operators::RuleProblem, Admin::RuleNotes.for(@secret).first.problem
        fine = create_permission_set_rule(permission_set: @vault, resource: @secrets, name: 'Fine', field_name: 'label',
                                          operator: 'equal', field_value: 'x')
        assert_empty Admin::RuleNotes.for(fine)
      end

      test 'Home\'s Fix rule opens a builder that says the rule compares a secret column' do
        doc = page("/permission_sets/#{@vault.id}/resources/PfSecretRecord/rules/#{@secret.id}/edit")

        banner = doc.at_css('[data-pf-rule-note="secret_column"]')
        assert banner, 'the builder banner'
        assert_includes banner.text, 'api_token'
        assert_includes banner.text, I18n.t('permission_forge.permission_set_rules.builder.notes.secret_column.title')
      end

      test 'the preview of that rule says it too, and the Rules tab badges the row' do
        preview = page("/permission_sets/#{@vault.id}/resources/PfSecretRecord/rules/preview",
                       rule_id: @secret.id, rule: { name: 'Token rule', field_name: 'api_token', operator: 'is_not_null' })
        assert preview.at_css('[data-pf-rule-note="secret_column"]'), 'the preview names the note'

        tab = page("/permission_sets/#{@vault.id}/resources/PfSecretRecord", tab: 'rules')
        row = tab.css('.pf-rule').find { |node| node.text.include?('Token rule') }
        assert row.at_css('[data-pf-rule-note="secret_column"]'), 'the Rules tab row badge'
      end

      test 'a rule that matches nothing keeps its banner and badge, from the same list' do
        doc = page("/permission_sets/#{@set.id}/resources/Customer/rules/#{create_broken_rule.id}/edit")
        assert doc.at_css('[data-pf-rule-note="matches_nothing"]')
        tab = page("/permission_sets/#{@set.id}/resources/Customer", tab: 'rules')
        assert tab.at_css('.pf-rule [data-pf-rule-note="matches_nothing"]')
      end

      test 'the builder offers no encrypted column, but keeps the one a stored rule names' do
        notes = create_resource(permission_set: @vault, name: 'PfEncryptedNote', read_access: true)
        form = Admin::RuleForm.new(resource: notes)
        assert_not_includes form.field_options.map(&:name), 'body'
        assert_includes form.field_options.map(&:name), 'title'

        stored = create_permission_set_rule(permission_set: @vault, resource: notes, name: 'Body set', field_name: 'title',
                                            operator: 'is_not_null', field_value: nil)
        stored.update_columns(field_name: 'body')
        assert_includes Admin::RuleForm.new(resource: notes, rule: stored).field_options.map(&:name), 'body'
      end

      private

      def create_broken_rule
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Typo', field_name: 'name', field_value: 'x')
          .tap { |rule| rule.update_columns(field_name: 'stauts') }
      end
    end
  end
end
