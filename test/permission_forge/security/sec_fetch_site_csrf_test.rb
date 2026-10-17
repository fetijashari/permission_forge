# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # Rails 8.2 verifies a mutating request by the browser's Sec-Fetch-Site
    # header, and `load_defaults 8.2` (the dummy app's, on Rails 8.2) selects
    # :header_only, which lets a plain-HTTP request without the header
    # through unchecked. The admin screens and the API keep
    # :header_or_legacy_token (ForgeryProtection): a cross-site request is
    # refused, a same-origin one passes, and one without the header needs the
    # token (admin_csrf_test.rb, api_csrf_test.rb).
    class SecFetchSiteCsrfTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      ROOT = '/permission_forge'
      ENGINE_CONTROLLERS = [
        PermissionForge::ApplicationController,
        PermissionForge::AssetsController,
        PermissionForge::Api::BaseController,
        PermissionForge::Api::PermissionSetsController
      ].freeze

      setup do
        skip 'Rails before 8.2 has no Sec-Fetch-Site verification' unless strategies?

        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        @set = create_permission_set(name: 'Target')
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery if strategies?
      end

      def strategies?
        ActionController::Base.respond_to?(:forgery_protection_verification_strategy)
      end

      def sign_in_by_session
        PermissionForge.configuration.api_auth = ->(c) { c.session[:permission_forge_locale] == 'sq' }
        get "#{ROOT}/permission_sets", params: { locale: 'sq' }
        assert_response :ok
      end

      def admin_token
        get "#{ROOT}/permission_sets/#{@set.id}/bulk_assignment/new"
        response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      end

      test 'every engine controller verifies by the header or the token, whatever the host chose' do
        ENGINE_CONTROLLERS.each do |controller|
          assert_equal :header_or_legacy_token, controller.forgery_protection_verification_strategy, controller.name
        end
      end

      test 'the engine keeps its strategy when the host base controller selects :header_only' do
        host = Class.new(ActionController::Base) { protect_from_forgery using: :header_only, with: :exception }
        engine = Class.new(host) do
          include PermissionForge::ForgeryProtection

          protect_from_forgery with: :exception, **pf_forgery_strategy
        end

        assert_equal :header_only, host.forgery_protection_verification_strategy
        assert_equal :header_or_legacy_token, engine.forgery_protection_verification_strategy
      end

      test 'admin: a cross-site POST is refused even with a valid token' do
        token = admin_token

        assert_raises(ActionController::InvalidCrossOriginRequest) do
          post "#{ROOT}/permission_sets/#{@set.id}/bulk_assignment/preview",
               params: { authenticity_token: token, identifiers: 'nobody@x.test' },
               headers: { 'Sec-Fetch-Site' => 'cross-site' }
        end
      end

      test 'admin: a same-origin POST passes without a token' do
        post "#{ROOT}/permission_sets/#{@set.id}/bulk_assignment/preview",
             params: { identifiers: 'nobody@x.test' }, headers: { 'Sec-Fetch-Site' => 'same-origin' }

        assert_response :success
      end

      test 'admin: a POST over HTTPS without the header still needs the token' do
        https!

        assert_raises(ActionController::InvalidCrossOriginRequest) do
          post "#{ROOT}/permission_sets/#{@set.id}/bulk_assignment/preview", params: { identifiers: 'nobody@x.test' }
        end
      end

      test 'the static admin assets are not varied by Sec-Fetch-Site, the admin pages are' do
        get "#{ROOT}/pf-assets/pf_admin.js"
        assert_response :ok
        assert_not_includes response.headers['Vary'].to_s, 'Sec-Fetch-Site'

        get "#{ROOT}/permission_sets"
        assert_includes response.headers['Vary'].to_s, 'Sec-Fetch-Site'
      end

      test 'API: a cross-site POST with the session cookie is refused and creates nothing' do
        sign_in_by_session

        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } },
                                              headers: { 'Sec-Fetch-Site' => 'cross-site' }
        end
        # :null_session empties the session, so api_auth (which reads it)
        # refuses: 401, as every refusing api_auth answers since 0.15.
        assert_response :unauthorized
      end

      test 'API: a same-origin POST with the session cookie passes' do
        sign_in_by_session

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'same origin' } },
                                            headers: { 'Sec-Fetch-Site' => 'same-origin' }

        assert_response :created
      end
    end
  end
end
