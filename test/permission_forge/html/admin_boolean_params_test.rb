# frozen_string_literal: true

require_relative 'admin_test_case'

module PermissionForge
  module Html
    # A flag the admin cannot read is refused with a flash, never read as true
    # and never a 500 (round 7, the S2 siblings). The admin's forms post "0"
    # and "1" (a hidden field and a checkbox); ActiveModel's cast read any
    # other word as true, so a crafted `group[is_active]=nope` switched a
    # group on. Every admin flag is read by ParamShapes.boolean, the API's
    # one definition.
    class AdminBooleanParamsTest < AdminTestCase
      UNREADABLE = %w[nope yes 2].freeze

      setup do
        @action = create_resource_action(resource: @resource, is_permitted: false, is_active: false)
        @group = create_permission_set_group(name: 'Team', is_active: false)
        @email.update!(is_active: false)
      end

      test 'a field drawer flag the admin cannot read is a flash, and the field is unchanged' do
        UNREADABLE.each do |value|
          patch pf("/permission_sets/#{@set.id}/resources/Customer/fields/email"), params: { field: { is_active: value } },
                                                                                   headers: referer
          assert_refused(value)
        end
        assert_not @email.reload.is_active
      end

      test 'a group flag the admin cannot read is a flash, and the group is unchanged' do
        UNREADABLE.each do |value|
          patch pf("/groups/#{@group.id}"), params: { group: { is_active: value } }, headers: referer
          assert_refused(value)
        end
        assert_not @group.reload.is_active
      end

      test 'an action flag the admin cannot read is a flash; nothing is created or changed' do
        base = "/permission_sets/#{@set.id}/resources/Customer/actions"
        UNREADABLE.each do |value|
          patch pf("#{base}/#{@action.id}"), params: { resource_action: { is_permitted: value } }, headers: referer
          assert_refused(value)
          assert_no_difference(-> { PermissionForge::ResourceAction.count }) do
            post pf(base), params: { resource_action: { name: 'archive', is_active: value } }, headers: referer
          end
          assert_refused(value)
        end
        assert_not @action.reload.is_permitted
      end

      test 'a flag the set editor cannot read is a flash, and nothing is applied' do
        UNREADABLE.each do |value|
          patch pf("/permission_sets/#{@set.id}/apply"), params: { pf: { resources: { @resource.id => { delete_access: value } } } },
                                                         headers: referer
          assert_refused(value)
        end
        assert_not @resource.reload.delete_access
      end

      test 'the words the forms post, and the other words of a boolean, are read' do
        { '1' => true, '0' => false, 'on' => true, 'off' => false, 'TRUE' => true, 'f' => false }.each do |value, expected|
          patch pf("/groups/#{@group.id}"), params: { group: { is_active: value } }
          assert_equal expected, @group.reload.is_active, value
        end
      end

      private

      def referer = { 'HTTP_REFERER' => "http://www.example.com#{pf("/permission_sets/#{@set.id}")}" }

      def assert_refused(value)
        assert_response :see_other, "#{value.inspect}: #{response.body[0, 200]}"
        assert_redirected_to pf("/permission_sets/#{@set.id}")
        assert_includes flash[:alert].to_s, I18n.t('permission_forge.api.errors.boolean_invalid'), value
      end
    end
  end
end
