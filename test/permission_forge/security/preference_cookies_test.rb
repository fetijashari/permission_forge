# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # The admin's preference cookies (pf_theme, pf_help) are Secure when the
    # admin is served over HTTPS, and stay HttpOnly, SameSite=Lax and scoped
    # to the mount path either way.
    class PreferenceCookiesTest < ActionDispatch::IntegrationTest
      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      def theme_cookie
        Array(response.headers['Set-Cookie']).flat_map { |line| line.split("\n") }.find { |line| line.start_with?('pf_theme=') }
      end

      test 'over HTTPS the cookie is Secure' do
        https!
        patch '/permission_forge/preferences', params: { theme: 'dark' }

        cookie = theme_cookie
        assert_match(/;\s*secure/i, cookie)
        assert_match(/;\s*httponly/i, cookie)
        assert_match(%r{;\s*path=/permission_forge}i, cookie)
      end

      test 'over plain HTTP the cookie is not marked Secure (the browser would drop it)' do
        patch '/permission_forge/preferences', params: { theme: 'dark' }

        cookie = theme_cookie
        assert cookie
        assert_no_match(/;\s*secure/i, cookie)
      end
    end
  end
end
