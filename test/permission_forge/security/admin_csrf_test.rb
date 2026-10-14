require 'test_helper'

module PermissionForge
  module Security
    # The admin keeps CSRF protection on. Forms with extra `formaction`
    # buttons must still verify: the token rendered in the form has to be
    # accepted by every action those buttons submit to.
    class AdminCsrfTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        @set = create_permission_set(name: 'Sales rep')
        create_resource(permission_set: @set, read_access: true)
        @base = "/permission_forge/permission_sets/#{@set.id}"
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      def form_token(path)
        get path
        response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      end

      test 'rule builder refresh accepts the builder form token' do
        token = form_token("#{@base}/resources/Customer/rules/new")

        post "#{@base}/resources/Customer/rules/refresh",
             params: { authenticity_token: token, rule: { name: 'Mine', path: ['supplier'], operator: 'equal' } }

        assert_response :success
      end

      test 'bulk "Check names" accepts the bulk form token' do
        token = form_token("#{@base}/bulk_assignment/new")

        post "#{@base}/bulk_assignment/preview", params: { authenticity_token: token, identifiers: 'nobody@x.test' }

        assert_response :success
      end

      test 'requests without a token are still rejected' do
        assert_raises(ActionController::InvalidAuthenticityToken) do
          post "#{@base}/bulk_assignment/preview", params: { identifiers: 'nobody@x.test' }
        end
      end
    end
  end
end
