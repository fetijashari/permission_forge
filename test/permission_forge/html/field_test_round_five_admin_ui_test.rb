require_relative 'admin_test_case'
require_relative 'a11y_lint'

module PermissionForge
  module Html
    # Admin findings of the fifth recorded field test (pf-showcase-5) and its
    # review: lists joined in the page's language, the rule builder's own
    # labels on a refused save, a locked rule that matches nothing on Home,
    # read-only inputs, fixing a misspelled relationship, a broken name as
    # stored, the footer of a change with no actor, and the description
    # placeholder at phone width.
    class FieldTestRoundFiveAdminUiTest < AdminTestCase
      LOCALES = %w[en sq mk].freeze
      ROOT_DIR = File.expand_path('../../..', __dir__)
      CSS = File.read(File.join(ROOT_DIR, 'app/frontend/permission_forge/pf_admin.css'))

      def t(key, **)
        I18n.t("permission_forge.#{key}", **)
      end

      def body
        CGI.unescapeHTML(response.body)
      end

      def rules_base = "/permission_sets/#{@set.id}/resources/Customer/rules"

      # --- 1. Lists in the page's language (b #81) -------------------------------------

      test 'nothing in app/ or lib/ joins a list with a bare to_sentence' do
        offenders = Dir[File.join(ROOT_DIR, '{app,lib}/**/*.{rb,erb}')].filter_map do |path|
          next if path.end_with?('lib/permission_forge/admin/list_sentence.rb')

          lines = File.readlines(path).each_with_index.select { |line, _| line.match?(/\.to_sentence\b/) }
          lines.map { |_, index| "#{path.delete_prefix("#{ROOT_DIR}/")}:#{index + 1}" }.presence
        end

        assert_empty offenders.flatten, 'use pf_to_sentence (Admin::ListSentence): to_sentence reads Rails\' support.array, ' \
                                        'English in an app without rails-i18n'
      end

      test 'a list reads with the connectors of each locale' do
        expected = { 'en' => 'Ana, Bo, and Cy', 'sq' => 'Ana, Bo dhe Cy', 'mk' => 'Ana, Bo и Cy' }
        expected.each do |locale, sentence|
          I18n.with_locale(locale) do
            assert_equal sentence, PermissionForge::Admin::ListSentence.call(%w[Ana Bo Cy])
            assert_equal sentence.sub('Ana, ', '').sub(',', ''), PermissionForge::Admin::ListSentence.call(%w[Bo Cy])
          end
        end
      end

      test 'the Permission Set page names its people in Macedonian and Albanian' do
        create_permission_set_user(user: @bo, permission_set: @set)

        { 'sq' => ' dhe ', 'mk' => ' и ' }.each do |locale, connector|
          get pf("/permission_sets/#{@set.id}"), params: { locale: locale }

          assert_response :success
          impact = css_select('.pf-impact').first.text.squish
          assert_includes impact, "Ana Krasniqi#{connector}Bo Berisha"
          assert_not_includes impact, ' and '
        end
      end

      # --- 2. The rule builder's own labels on a refused save (review) -----------------

      test 'a refused save names the field as the builder does, in every locale' do
        LOCALES.each do |locale|
          post pf(rules_base), params: { locale: locale, rule: { name: 'Range', field_name: 'name', operator: 'between',
                                                                 value_from: '1,2', value_to: '3' } }

          assert_response :unprocessable_entity
          I18n.with_locale(locale) do
            errors = css_select('.pf-sheet__footer-note .pf-error').map { |node| node.text.squish }
            label = t('permission_set_rules.value_input.value')
            message = t('validations.permission_set_rule.between_requires_two_values').squish
            assert_includes errors, "#{label} #{message}"
            assert(errors.none? { |error| error.start_with?('Field value') }, "#{locale}: #{errors}")
          end
        end
      end

      test 'the builder labels a refused relationship "Relationship", not "Field accessor path"' do
        rule = PermissionForge::PermissionSetRule.new(resource: @resource, permission_set: @set, name: 'Own',
                                                      field_accessor_path: 'ownr', join_type: 'joins',
                                                      field_name: 'owner_id', operator: 'equal', field_value: '1')
        assert_not rule.valid?
        form = PermissionForge::Admin::RuleForm.new(resource: @resource, rule: rule)

        LOCALES.each do |locale|
          I18n.with_locale(locale) do
            errors = PermissionForge::Admin::RuleBuilder.new(form: form, resource: @resource, model_errors: rule.errors)
                                                        .model_errors
            relationship = errors.find { |error| error.include?('ownr') }
            assert relationship, "#{locale}: #{errors}"
            assert relationship.start_with?(t('permission_set_rules.builder.relationship')), relationship
            assert_not_includes relationship, 'accessor'
          end
        end
      end

      # --- 3. A locked rule that matches nothing on Home (b #62) -----------------------

      def broken_rule
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Status', field_name: 'name',
                                          field_value: 'active')
        rule.update_columns(field_name: 'stauts')
        rule
      end

      test 'Home shows the Locked badge on a locked rule and says where it gets fixed' do
        broken_rule
        @set.update_columns(is_editable: false)

        LOCALES.each do |locale|
          get pf('/'), params: { locale: locale }

          assert_response :success
          assert_no_missing_translations
          I18n.with_locale(locale) do
            row = css_select("section[aria-labelledby='pf-card-broken-rules'] .pf-card__row").first
            assert row.at_css('.pf-badge').text.include?(t('ui.badges.locked')), 'the row carries the Locked badge'
            assert_includes row.css('code').map(&:text), 'is_editable: false'
            assert_includes row.text.squish, t('home.broken_rules_card.locked_fix_html', flag: 'is_editable: false').squish
          end
        end
      end

      test 'an editable rule that matches nothing has no Locked badge and no locked note' do
        broken_rule
        get pf('/')

        row = css_select("section[aria-labelledby='pf-card-broken-rules'] .pf-card__row").first
        assert_nil row.at_css('.pf-badge')
        assert_not_includes row.text, 'is_editable: false'
      end

      # --- 4. Read-only inputs look read-only (b #51) -----------------------------------

      test 'read-only inputs are drawn filled, without the hover of an editable one' do
        assert_match(/\.pf-root \.pf-input\[readonly\], \.pf-root \.pf-textarea\[readonly\] \{ background: var\(--pf-surface-2\);/, CSS)
        assert_match(/\.pf-root \.pf-input\[readonly\]:hover, \.pf-root \.pf-textarea\[readonly\]:hover \{ border-color: var\(--pf-border\); \}/,
                     CSS)
        assert_match(/\.pf-title-input\[readonly\]:hover, \.pf-desc-input\[readonly\]:hover \{ border-color: transparent; \}/, CSS)
      end

      test 'a locked field drawer keeps Label and Description read-only, labelled' do
        @set.update_columns(is_editable: false)
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email")

        assert_response :success
        assert_select '#pf-fd-label[readonly]', 1
        assert_select '#pf-fd-desc[readonly]', 1
        assert_select "label[for='pf-fd-label']", 1
        assert_select "label[for='pf-fd-desc']", 1
      end

      # --- 5. Fixing a misspelled relationship (e #55-60, a #109) -----------------------

      def misspelled_join_rule
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own', field_accessor_path: 'supplier',
                                          join_type: 'joins', field_name: 'owner_id', operator: 'equal', field_value: 'current_user',
                                          include_nulls: false)
        rule.update_columns(field_accessor_path: 'ownr')
        rule
      end

      test 'a relationship that is not there shows "Pick a relationship…", not the first one as if chosen' do
        rule = misspelled_join_rule
        get pf("#{rules_base}/#{rule.id}/edit")

        assert_response :success
        select = css_select('#pf-rule-path-0').first
        assert_equal 'true', select['aria-invalid']
        chosen = select.css('option[selected]')
        assert_equal 1, chosen.size
        assert_equal t('permission_set_rules.builder.pick_relationship'), chosen.first.text
        assert_equal 'ownr', chosen.first['value'], 'a refresh keeps the stored path until another is picked'
        field = css_select('#pf-rule-field option[selected]')
        assert_equal ['owner_id'], field.map { |option| option['value'] }, 'the stored field is kept'
      end

      test 'picking the relationship again keeps the stored field when it is a column there' do
        post pf("#{rules_base}/refresh"), params: { rule: { name: 'Own', path: ['supplier'], field_name: 'owner_id',
                                                            operator: 'equal', current_user: '1' } }

        assert_response :success
        assert_select '#pf-rule-path-0 option[selected]', text: Supplier.model_name.human
        assert_select '#pf-rule-field option[selected][value=owner_id]', 1
      end

      test 'a stored field that is no column of the picked relationship is dropped' do
        post pf("#{rules_base}/refresh"), params: { rule: { name: 'Own', path: ['supplier'], field_name: 'nope_column',
                                                            operator: 'equal' } }

        assert_response :success
        assert_select '#pf-rule-field option[selected]', 0
        assert_select '#pf-rule-field option[value=nope_column]', 0
      end

      test 'a working rule shows neither placeholder nor kept field' do
        rule = misspelled_join_rule
        rule.update_columns(field_accessor_path: 'supplier')
        get pf("#{rules_base}/#{rule.id}/edit")

        assert_select '#pf-rule-path-0 option', text: t('permission_set_rules.builder.pick_relationship'), count: 0
        assert_select '#pf-rule-path-0[aria-invalid]', 0
        assert_select '#pf-rule-field option[selected][value=owner_id]', text: /owner_id/
      end

      # --- 6. A name that is not there, as stored (a #107) ------------------------------

      test 'a broken name is shown as stored, in code, wherever the problem is said' do
        broken_rule
        misspelled_join_rule

        get pf('/')
        card = css_select("section[aria-labelledby='pf-card-broken-rules']").first
        assert_equal %w[ownr stauts], card.css('.pf-text-block code').map(&:text).sort
        assert_not_includes card.text, 'Stauts'
        assert_not_includes card.text, 'Ownr'

        get pf("/people/#{@ana.id}?tab=effective")
        assert_includes body, '<code class="pf-mono-key">stauts</code>'
      end

      # --- 7. The footer of a change with no actor (b #63) ------------------------------

      test 'the footer and the event page explain Unknown with one helper and the same words' do
        PermissionForge.configuration.audit_trail_enabled = true
        old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.current_user_resolver = -> {}
        @set.update!(description: 'Changed from a runner')
        event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, actor_type: 'unknown')

        get pf("/permission_sets/#{@set.id}")
        footer_hint = css_select('.pf-audit-footer__hint').first.text.squish
        get pf("/audit/#{event.uuid}")
        page_hint = css_select('section[aria-labelledby=pf-event-who] p').find { |p| p.at_css('code') }.text.squish

        assert_equal page_hint, footer_hint
        assert_not footer_hint.start_with?(t('audit_log.actor_types.unknown'))
      ensure
        PermissionForge.configuration.current_user_resolver = old_resolver
      end

      # --- 8. The description placeholder at phone width (b #80) -----------------------

      # 340px of 14px text holds about 45 characters; the Macedonian one had 53.
      test 'the Permission Set description placeholder fits a phone-width input in every locale' do
        LOCALES.each do |locale|
          placeholder = I18n.t('permission_forge.permission_sets.header.description_placeholder', locale: locale)
          assert_operator placeholder.length, :<=, 40, "#{locale}: #{placeholder}"
        end
        assert_match(/\.pf-desc-input \{[^}]*text-overflow: ellipsis;/, CSS)
      end

      test 'the pages touched here are clean and translated in every locale' do
        broken_rule
        rule = misspelled_join_rule
        @set.update_columns(is_editable: false)
        paths = ['/', "/permission_sets/#{@set.id}", "/permission_sets/#{@set.id}/resources/Customer/fields/email"]
        failures = LOCALES.flat_map do |locale|
          paths.flat_map do |path|
            get pf(path), params: { locale: locale }
            assert_response :success
            assert_no_missing_translations
            A11yLint.new(response.body).problems.map { |problem| "#{locale} #{path}: #{problem}" }
          end
        end
        @set.update_columns(is_editable: true)
        LOCALES.each do |locale|
          get pf("#{rules_base}/#{rule.id}/edit"), params: { locale: locale }
          assert_no_missing_translations
          failures += A11yLint.new(response.body).problems.map { |problem| "#{locale} rule edit: #{problem}" }
        end

        assert_empty failures, failures.join("\n")
      end
    end
  end
end
