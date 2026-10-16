# frozen_string_literal: true

require_relative 'integration_support'
require 'active_job'

ActiveJob::Base.logger = Rails.logger

# A host job that renames a Permission Set, optionally as a named admin.
class PfT11RenameSetJob < ActiveJob::Base
  def perform(set_id, name, admin_id = nil)
    rename = -> { PermissionForge::PermissionSet.find(set_id).update!(name: name) }
    admin_id ? PermissionForge.with_audit_actor(user: User.find(admin_id), &rename) : rename.call
  end
end

module PermissionForge
  module AuditIntegration
    # Who did it, for each way a change reaches the gem — every one a real
    # change: [actor_type, actor_id, actor_label, source] of its event.
    class ActorMatrixTest < ActionDispatch::IntegrationTest
      include IntegrationSupport

      setup do
        @admin = create_user(name: ADMIN_NAME)
        @set = create_permission_set(name: 'Sales rep')
        PermissionForge.configuration.audit_trail_enabled = true
      end

      test 'a host user signed in to the admin UI' do
        sign_in(@admin)
        rename_through_admin_ui('By the admin')

        assert_actor ['user', @admin.id.to_s, ADMIN_NAME, 'admin_ui']
        assert_equal @admin.id, @set.reload.updated_by_id
      end

      test 'the admin named by audit_actor_resolver wins over the signed-in user' do
        sign_in(create_user(name: 'Session user'))
        PermissionForge.configuration.audit_actor_resolver = ->(_controller) { @admin }
        rename_through_admin_ui('By the resolver')

        assert_actor ['user', @admin.id.to_s, ADMIN_NAME, 'admin_ui']
      end

      test 'an HTTP Basic login to the admin UI' do
        basic_auth!
        rename_through_admin_ui('By ops')

        assert_actor ['basic_auth', nil, BASIC_USER, 'admin_ui']
        assert_nil @set.reload.updated_by_id, 'a shared login is no user to stamp'
      end

      test 'an API token named by audit_actor_resolver' do
        api_token!
        rename_through_api('By the token')

        assert_actor ['api', 'tok-7', 'CI deploy token', 'api']
      end

      test 'through the API too, the actor named by audit_actor_resolver wins over the signed-in user' do
        sign_in(create_user(name: 'Session user'))
        PermissionForge.configuration.audit_actor_resolver = ->(_controller) { API_ACTOR }
        rename_through_api('By the token, over a session')

        assert_actor ['api', 'tok-7', 'CI deploy token', 'api']
      end

      test 'a signed-in user through the API, and an API client nobody names' do
        sign_in(@admin)
        rename_through_api('By the admin over the API')
        assert_actor ['user', @admin.id.to_s, ADMIN_NAME, 'api']

        PermissionForge.configuration.current_user_resolver = -> {}
        rename_through_api('By an anonymous client')
        assert_actor ['api', nil, PermissionForge::Audit::ActorCodes::API_CLIENT, 'api']
      end

      test 'a rake task run with ACTOR=' do
        assignment = create_permission_set_user(user: create_user(name: 'Ana'), permission_set: @set)
        assignment.update_columns(expires_at: 1.day.ago)
        with_env('ACTOR' => 'ops: Grace (TCK-9)') { run_rake_task('permission_forge:cleanup_expired_assignments') }

        assert_actor ['system', nil, 'ops: Grace (TCK-9)', 'rake'], event: 'assignment.revoked'
      end

      test 'a job, with nobody named and with a named admin' do
        PfT11RenameSetJob.perform_now(@set.id, 'By a job')
        assert_actor ['unknown', nil, nil, 'job']

        PfT11RenameSetJob.perform_now(@set.id, 'By a job for the admin', @admin.id)
        assert_actor ['user', @admin.id.to_s, ADMIN_NAME, 'job']
      end

      test 'a console session naming the admin' do
        with_console { PermissionForge.with_audit_actor(user: @admin) { @set.update!(name: 'From the console') } }

        assert_actor ['user', @admin.id.to_s, ADMIN_NAME, 'console']
      end

      test 'nobody: a service call with no user and no context' do
        PermissionForge.configuration.current_user_resolver = -> {}
        @set.update!(name: 'By nobody')

        assert_actor ['unknown', nil, nil, 'service']
      end

      private

      def rename_through_admin_ui(name)
        patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { name: name } } }, headers: @auth_headers
        assert_response :redirect
      end

      def rename_through_api(name)
        patch "#{ROOT}/api/permission_sets/#{@set.uuid}", params: { permission_set: { name: name } }, as: :json
        assert_response :ok
      end

      def assert_actor(expected, event: 'permission_set.updated')
        found = AuditEvent.where(event: event).order(:id).last
        assert found, "a #{event} event"
        assert_equal expected, found.attributes.values_at(*%w[actor_type actor_id actor_label source])
      end

      def with_console
        defined_here = !defined?(::Rails::Console)
        ::Rails.const_set(:Console, Class.new) if defined_here
        yield
      ensure
        ::Rails.send(:remove_const, :Console) if defined_here && defined?(::Rails::Console)
      end
    end
  end
end
