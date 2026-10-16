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

      # Field test round 8 (D#7): with api_auth set and no authorization
      # lambda, the API refused every change, assignment and stats read, and
      # nothing said so before the first 403.
      test 'the boot names each authorization lambda the API needs and does not have, and what it refuses' do
        config = PermissionForge.configuration
        config.api_stats_require_admin = Configuration.new.api_stats_require_admin

        note = boot_log { BootChecks.send(:warn_configuration, config) }

        assert_equal 1, note.scan('[PermissionForge] The JSON API is on and api_auth admits callers').size, note
        assert_match(/api_action_authorization: every create, update, delete and copy; /, note)
        assert_match(/api_assignment_authorization: every assignment and group membership change; /, note)
        assert_match(%r{api_stats_authorization: GET /api/stats}, note)
        assert_no_match(/SECURITY warning: The JSON API/, note, 'it fails closed')

        config.api_action_authorization = ->(*) { true }
        config.api_assignment_authorization = ->(*) { true }
        config.api_stats_authorization = ->(_c) { true }
        assert_empty(boot_log { BootChecks.warn_api_authorizations_unset(config) })
      end

      test 'the install initializer shows all three authorization lambdas' do
        source = render_install_template('initializer.rb.tt')

        %w[api_action_authorization api_assignment_authorization api_stats_authorization].each do |option|
          assert_match(/^  # config\.#{option} = ->/, source, option)
        end
      end

      private

      def boot_log
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        yield
        log.string
      ensure
        Rails.logger = original
      end

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
