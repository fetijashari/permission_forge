# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # The JSON API's CSRF posture with forgery protection on: a cross-site
    # form post carries the victim's cookies but no CSRF token. The null
    # session has to be in place before api_auth runs, or a session- or
    # cookie-based api_auth sees the real session and lets the forged
    # mutation through (the 0.13 callback order did).
    class ApiCsrfTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      ROOT = '/permission_forge'

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        @set = create_permission_set(name: 'Target')
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      # A session the admin screens wrote: the locale switch stores it.
      def sign_in_by_session
        PermissionForge.configuration.api_auth = ->(c) { c.session[:permission_forge_locale] == 'sq' }
        get "#{ROOT}/permission_sets", params: { locale: 'sq' }
        assert_response :ok
      end

      def page_csrf_token
        get "#{ROOT}/permission_sets"
        response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
      end

      test 'these tests run on the shipped api_require_authorization (true)' do
        assert_equal true, PermissionForge.configuration.api_require_authorization
      end

      test 'the forgery check runs before the API is authenticated' do
        chain = PermissionForge::Api::PermissionSetsController._process_action_callbacks.map(&:filter)

        assert_operator chain.index(:verify_authenticity_token), :<, chain.index(:authenticate_api_request!)
        assert_operator chain.index(:verify_authenticity_token), :<, chain.index(:verify_api_enabled!)
        # Rails 8.2 verifies in a callback of its own; it is prepended too.
        verifier = chain.index(:verify_request_for_forgery_protection)
        assert_operator verifier, :<, chain.index(:authenticate_api_request!) if verifier
      end

      test 'a session-authenticated GET still passes (reads are not forgery-checked)' do
        sign_in_by_session

        get "#{ROOT}/api/permission_sets"

        assert_response :ok
      end

      test 'a forged POST with the session cookie is refused and creates nothing' do
        sign_in_by_session

        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }
        end
        assert_response :forbidden
      end

      test 'a forged PATCH and DELETE with the session cookie are refused' do
        sign_in_by_session

        patch "#{ROOT}/api/permission_sets/#{@set.uuid}", params: { permission_set: { name: 'forged' } }
        assert_response :forbidden
        delete "#{ROOT}/api/permission_sets/#{@set.uuid}"
        assert_response :forbidden

        assert_equal 'Target', @set.reload.name
      end

      test 'a forged POST authenticated by a plain cookie is refused' do
        PermissionForge.configuration.api_auth = ->(c) { c.request.cookie_jar['pf_csrf_probe'] == '1' }
        cookies['pf_csrf_probe'] = '1'

        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }
        end
        assert_response :forbidden
      end

      test 'a session-authenticated POST with a valid CSRF token passes' do
        sign_in_by_session
        token = page_csrf_token

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'same origin' } },
                                            headers: { 'X-CSRF-Token' => token }

        assert_response :created
      end

      test 'a token-authenticated request without a CSRF token still works' do
        PermissionForge.configuration.api_auth = ->(c) { c.request.headers['Authorization'] == 'Bearer s3cret' }

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'token client' } }.to_json,
                                            headers: { 'Authorization' => 'Bearer s3cret', 'Content-Type' => 'application/json' }

        assert_response :created
      end

      # The documented limit (docs/admin-api.md, CSRF): :null_session empties
      # the session and the cookie jar the controller reads. Identity read
      # from anywhere else is still the victim's on a forged request: the raw
      # Cookie header / Rack's request.cookies, anything a middleware put in
      # the env before the controller (a Warden user it already loaded), and
      # credentials the browser attaches by itself (cached HTTP Basic).
      test 'limit: identity read outside the session and the cookie jar is not emptied' do
        cookies['pf_csrf_probe'] = '1'
        basic = ActionController::HttpAuthentication::Basic.encode_credentials('admin', 'pw')
        {
          ->(c) { c.request.cookies['pf_csrf_probe'] == '1' } => {},
          ->(c) { c.request.env['pf.identity'] == 'admin' } => { env: { 'pf.identity' => 'admin' } },
          ->(c) { ActionController::HttpAuthentication::Basic.has_basic_credentials?(c.request) } =>
            { headers: { 'Authorization' => basic } }
        }.each do |auth, options|
          PermissionForge.configuration.api_auth = auth
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }, **options
          assert_response :created
        end
      end

      test 'the refusal of a forged request is recorded' do
        sign_in_by_session

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'forged' } }

        assert_audit_event('api.auth_failed', data: { 'reason' => 'api_auth_denied' })
      end
    end

    # An ActionController::API base has no forgery protection (and no
    # cookies): the base controller's class body must still load on it.
    class ApiCsrfApiBaseTest < ActiveSupport::TestCase
      SOURCE = File.read(File.expand_path('../../../app/controllers/permission_forge/api/base_controller.rb', __dir__))

      test 'the base controller builds on ActionController::API' do
        original = PermissionForge.configuration.api_base_controller_class
        PermissionForge.configuration.api_base_controller_class = '::ActionController::API'
        sandbox = Module.new
        PermissionForge.const_set(:ApiCsrfSandbox, sandbox)
        sandbox.module_eval(SOURCE.sub('module PermissionForge', 'module PermissionForge::ApiCsrfSandbox'), __FILE__, 1)

        base = PermissionForge::ApiCsrfSandbox::Api::BaseController
        assert_operator base, :<, ActionController::API
        assert_not base.respond_to?(:protect_from_forgery)
      ensure
        PermissionForge.configuration.api_base_controller_class = original
        PermissionForge.send(:remove_const, :ApiCsrfSandbox) if PermissionForge.const_defined?(:ApiCsrfSandbox, false)
      end
    end
  end
end
