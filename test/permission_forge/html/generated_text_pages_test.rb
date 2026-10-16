require_relative 'admin_test_case'
require 'nokogiri'

module PermissionForge
  module Html
    # Field test round 7 (A#127, B#26), on the admin's pages: a field or
    # action row labelled with English the gem made up is shown as a column
    # with no label — in Albanian and Macedonian its name in <code>, on an
    # English page Rails' own English — so a configured row and a column
    # nobody configured carry the same name, on a granting and on a muting
    # set; the field drawer and the action form pre-fill no generated label;
    # a rule's install-default blocked message is never shown as the admin's.
    class GeneratedTextPagesTest < AdminTestCase
      INSTALL_MESSAGE = 'You do not have permission to perform this action.'.freeze

      def fields_tab(set, locale)
        get pf("/permission_sets/#{set.id}/resources/Customer"), params: { tab: 'fields', locale: locale }
        assert_response :success
        Nokogiri::HTML(response.body)
      end

      # The name a row of the Fields tab shows for `column`: its label (when
      # one is drawn) and its <code>.
      def row_name(doc, column)
        row = doc.css('.pf-fields__row').find { |node| node.at_css('code.pf-mono-key')&.text == column }
        assert row, "no row for #{column}"
        row.at_css('.pf-fields__name').text.squish
      end

      [false, true].each do |muting|
        test "a generated label and no row read the same on a #{muting ? 'muting' : 'granting'} set, in every language (B#26)" do
          set = create_permission_set(name: "Labels #{muting}", is_muting: muting)
          resource = create_resource(permission_set: set, read_access: !muting)
          create_resource_field(resource: resource, name: 'domain', read_access: true).update_columns(label: 'Domain')

          { 'en' => ['Domain domain', 'Supplier supplier_id'], 'sq' => %w[domain supplier_id], 'mk' => %w[domain supplier_id] }
            .each do |locale, (configured, unconfigured)|
            doc = fields_tab(set, locale)
            assert_equal configured, row_name(doc, 'domain'), "#{locale}: the configured row"
            assert_equal unconfigured, row_name(doc, 'supplier_id'), "#{locale}: the column nobody configured"
          end
        end
      end

      test 'the field drawer pre-fills no generated label, and keeps an admin label' do
        @email.update_columns(label: 'Email')
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"), params: { locale: 'sq' }
        assert_equal '', Nokogiri::HTML(response.body).at_css('#pf-fd-label')['value'].to_s

        @email.update_columns(label: 'Billing contact')
        get pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"), params: { locale: 'sq' }
        assert_equal 'Billing contact', Nokogiri::HTML(response.body).at_css('#pf-fd-label')['value']
      end

      test 'the action form pre-fills no generated label' do
        action = create_resource_action(resource: @resource, name: 'export_csv', label: 'Export csv')
        get pf("/permission_sets/#{@set.id}/resources/Customer/actions/#{action.id}"), params: { locale: 'mk' }
        assert_response :success
        assert_equal '', Nokogiri::HTML(response.body).at_css('#pf-action-label')['value'].to_s
      end

      test 'a rule whose blocked message is the install default shows none as the admin wrote' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own')
        rule.update_columns(failure_message: INSTALL_MESSAGE)

        get pf("/permission_sets/#{@set.id}/resources/Customer"), params: { tab: 'rules', locale: 'sq' }
        assert_not_includes response.body, INSTALL_MESSAGE
        get pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{rule.id}/edit"), params: { locale: 'sq' }
        assert_not_includes response.body, INSTALL_MESSAGE, 'the builder pre-fills no generated message'
      end

      test 'a set and a rule stored under an install default name are named in the page language' do
        @set.update_columns(name: 'Untitled Permission Set')
        create_permission_set_rule(permission_set: @set, resource: @resource).update_columns(name: 'Untitled Rule')

        get pf("/permission_sets/#{@set.id}/resources/Customer"), params: { tab: 'rules', locale: 'sq' }
        assert_response :success
        assert_not_includes response.body, 'Untitled Permission Set'
        assert_not_includes response.body, 'Untitled Rule'
        assert_includes response.body, I18n.t('permission_forge.ui.untitled.permission_set', locale: :sq)
        assert_includes response.body, I18n.t('permission_forge.ui.untitled.permission_set_rule', locale: :sq)
      end
    end
  end
end
