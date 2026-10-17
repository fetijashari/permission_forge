require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Review of round 7 P1+P2 (P2-6): the rule builder read its three flags
    # (`current_user`, `include_nulls`, `is_active`) with `== '1'`, so "true"
    # and "on" read as false — beside the one boolean reading of the admin
    # and the API (ParamShapes.boolean). They go through it now: a word it
    # reads is taken, anything else is the admin's flash path
    # (ParamShapes::InvalidFlag), nothing saved; an unchecked box (absent)
    # keeps its default.
    class RuleFormFlagsTest < AdminTestCase
      def rules_path = pf("/permission_sets/#{@set.id}/resources/Customer/rules")

      def created(name) = PermissionForge::PermissionSetRule.find_by(name: name)

      test 'the builder reads "true", "on", "off" as the one boolean reading does' do
        post rules_path, params: { rule: { name: 'Words', field_name: 'supplier_id', operator: 'equal', current_user: 'true',
                                           include_nulls: 'on', is_active: 'OFF' } }
        assert_response :redirect

        rule = created('Words')
        assert_equal ['current_user', true, false], [rule.field_value, rule.include_nulls, rule.is_active]
      end

      test 'an absent box keeps its default; "0" is false' do
        post rules_path, params: { rule: { name: 'Absent', field_name: 'name', operator: 'equal', value: 'x' } }
        rule = created('Absent')
        assert_equal [false, true, 'x'], [rule.include_nulls, rule.is_active, rule.field_value]

        post rules_path, params: { rule: { name: 'Zero', field_name: 'name', operator: 'equal', value: 'x', is_active: '0' } }
        assert_equal false, created('Zero').is_active
      end

      %w[current_user include_nulls is_active].each do |flag|
        test "a #{flag} the admin cannot read goes back with the flash, nothing saved" do
          assert_no_difference -> { PermissionForge::PermissionSetRule.count } do
            post rules_path, params: { rule: { name: 'Unreadable', field_name: 'name', operator: 'equal', value: 'x', flag => 'yes' } }
          end
          assert_response :see_other
          assert_equal I18n.t('permission_forge.flash.invalid_param', param: flag, detail: I18n.t('permission_forge.api.errors.boolean_invalid')),
                       flash[:alert]
        end
      end
    end
  end
end
