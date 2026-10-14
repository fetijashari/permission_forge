require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Admins must not assume a record rule applies to every query when the app's
    # query scoping only applies it to find_by / permission_scoped lookups.
    class RuleScopingNoticeTest < AdminTestCase
      setup do
        @rules_tab = pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules")
      end

      test 'no rules: the empty state says records are not limited' do
        get @rules_tab

        assert_match 'records aren&#39;t limited', response.body
        assert_select '.pf-banner--warn', count: 0
      end

      test 'active rules with scoping off: rules tab warns and home lists them' do
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own rows')

        get @rules_tab
        assert_select '.pf-banner--warn', text: /Automatic query scoping is off/

        get pf('/')
        assert_select '#pf-card-rules', text: I18n.t('permission_forge.home.rules_card.title')
        assert_match 'Open rules', response.body
      end

      test 'with scoping on, filter rules are not flagged but join rules are' do
        old = PermissionForge.configuration.auto_query_scoping
        PermissionForge.configuration.auto_query_scoping = :filter_only
        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own rows')

        get @rules_tab
        assert_select '.pf-banner--warn', count: 0
        get pf('/')
        assert_select '#pf-card-rules', count: 0

        create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Via supplier',
                                   join_type: 'joins', field_accessor_path: 'supplier')
        get @rules_tab
        assert_select '.pf-banner--warn', text: /follow a relationship/
      ensure
        PermissionForge.configuration.auto_query_scoping = old
      end
    end
  end
end
