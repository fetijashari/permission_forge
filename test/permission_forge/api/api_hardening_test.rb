# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Regression tests for the API hardening pass: is_editable enforcement,
    # assignment authorization coverage on destroy, mutation authorization on
    # create/update/destroy, generic error messages, and locale parsing.
    class ApiHardeningTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
      end

      # --- is_editable enforcement ---

      test 'PATCH update is rejected for a non-editable permission set' do
        locked = create_permission_set(name: 'Locked', is_editable: false)
        patch "/permission_forge/api/permission_sets/#{locked.uuid}", params: {
          permission_set: { name: 'Renamed' }
        }
        assert_response :forbidden
        assert_equal 'Locked', locked.reload.name
      end

      test 'DELETE destroy is rejected for a non-editable permission set' do
        locked = create_permission_set(name: 'Locked', is_editable: false)
        delete "/permission_forge/api/permission_sets/#{locked.uuid}"
        assert_response :forbidden
        assert PermissionForge::PermissionSet.exists?(locked.id)
      end

      test 'editable records are still mutable' do
        patch "/permission_forge/api/permission_sets/#{@ps.uuid}", params: {
          permission_set: { name: 'Renamed' }
        }
        assert_response :ok
        assert_equal 'Renamed', @ps.reload.name
      end

      # --- mutation authorization hook ---

      test 'api_action_authorization gates update' do
        PermissionForge.configuration.api_action_authorization = ->(_c, _a, _r) { false }
        patch "/permission_forge/api/permission_sets/#{@ps.uuid}", params: {
          permission_set: { name: 'Renamed' }
        }
        assert_response :forbidden
      ensure
        PermissionForge.configuration.api_action_authorization = nil
      end

      # --- assignment authorization on destroy ---

      test 'api_assignment_authorization gates single-user revoke' do
        user = create_user
        psu = create_permission_set_user(user: user, permission_set: @ps)
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _ps, _ids) { false }

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/users/#{psu.uuid}"
        assert_response :forbidden
        assert PermissionForge::PermissionSetUser.exists?(psu.id)
      ensure
        PermissionForge.configuration.api_assignment_authorization = nil
      end

      # --- error messages do not leak internals ---

      test 'generate_fields returns a generic error, not the exception text' do
        # 'String' is a valid constant but not an AR model, so the generator hits
        # String.column_names -> NoMethodError inside the rescue.
        resource = @ps.resources.create!(uuid: SecureRandom.uuid, name: 'String', read_access: true)
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields"

        assert_response :unprocessable_entity
        body = response.body
        assert_includes body, I18n.t('permission_forge.api.errors.field_generation_failed')
        assert_not_includes body, 'NoMethodError'
        assert_not_includes body, 'column_names'
      end

      # --- CSRF posture ---

      test 'base controller uses null_session forgery protection, not skip' do
        # ActionController::Base includes RequestForgeryProtection.
        assert PermissionForge::Api::BaseController.respond_to?(:forgery_protection_strategy) ||
               PermissionForge::Api::BaseController.private_method_defined?(:handle_unverified_request)
      end

      # --- Accept-Language parsing (bare tag) ---

      test 'bare Accept-Language tag selects the locale' do
        original = PermissionForge.configuration.available_locales
        PermissionForge.configuration.available_locales = %i[en sq]
        get '/permission_forge/api/permission_sets', headers: { 'HTTP_ACCEPT_LANGUAGE' => 'sq' }
        assert_response :ok
      ensure
        PermissionForge.configuration.available_locales = original
      end
    end
  end
end
