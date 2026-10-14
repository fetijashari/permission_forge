require 'test_helper'

module PermissionForge
  module Html
    # Shared setup for admin UI integration tests: CSRF off (the dummy app keeps
    # it on for the API posture tests) and a small realistic data set.
    class AdminTestCase < ActionDispatch::IntegrationTest
      ROOT = '/permission_forge'.freeze

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = create_user(name: 'Bo Berisha', email: 'bo@acme.test')
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true, edit_access: true)
        @email = create_resource_field(resource: @resource, name: 'email', read_access: true, mask_access: true,
                                       mask_strategy: 'email')
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      private

      def pf(path)
        "#{ROOT}#{path}"
      end

      def assert_no_missing_translations
        assert_no_match(/translation[ _]missing/i, response.body)
      end

      # A form's default button must stay rendered: Safari before 16.4 skips a
      # display:none (`hidden`) button when Enter looks for the default button.
      # So it is clipped out of sight, out of the tab order and out of the
      # accessibility tree instead.
      def assert_out_of_sight_but_rendered(button)
        assert_not button.key?('hidden'), 'a hidden default button is ignored by Safari before 16.4'
        assert_includes button['class'].to_s.split, 'pf-sr-only', 'the default button is not shown'
        assert_equal '-1', button['tabindex'], 'the default button is not a tab stop'
        assert_equal 'true', button['aria-hidden'], 'the default button is not announced'
      end
    end
  end
end
