# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Security
    # api_require_authorization is on by default: an api_auth that only
    # proves identity no longer makes every caller a permission admin. The
    # suite's test_helper opts out (false) for convenience; these tests use
    # the shipped default.
    class ApiRequireAuthorizationDefaultTest < ActionDispatch::IntegrationTest
      ROOT = '/permission_forge/api'

      setup do
        PermissionForge.configuration.api_require_authorization = Configuration.new.api_require_authorization
        @set = create_permission_set(name: 'Target')
        @user = create_user
      end

      test 'with the default, a mutation without api_action_authorization is refused' do
        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/permission_sets", params: { permission_set: { name: 'Escalate' } }
        end
        assert_response :forbidden
      end

      test 'with the default, an assignment without api_assignment_authorization is refused' do
        assert_no_difference -> { PermissionForge::PermissionSetUser.count } do
          post "#{ROOT}/permission_sets/#{@set.uuid}/users", params: { user_id: @user.id }
        end
        assert_response :forbidden
      end

      test 'with the default, configured authorization lambdas decide' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _a, _r) { true }

        post "#{ROOT}/permission_sets", params: { permission_set: { name: 'Allowed' } }

        assert_response :created
      end

      test 'reads are not affected' do
        get "#{ROOT}/permission_sets"

        assert_response :ok
      end

      test 'the opt-out lets identity-only callers change permissions (and the boot warning says so)' do
        PermissionForge.configuration.api_require_authorization = false

        post "#{ROOT}/permission_sets", params: { permission_set: { name: 'Opted out' } }
        assert_response :created

        assert_match(/api_require_authorization is false/, boot_warning)
      end

      test 'no boot warning under the default' do
        assert_empty boot_warning
      end

      test 'the install initializer documents the default' do
        assert_includes render_install_template('initializer.rb.tt'), '# config.api_require_authorization = true  # default'
      end

      private

      def boot_warning
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        PermissionForge::BootChecks.warn_api_authorization_gap(PermissionForge.configuration)
        log.string
      ensure
        Rails.logger = original
      end
    end
  end
end
