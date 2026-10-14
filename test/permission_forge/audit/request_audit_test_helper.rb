# frozen_string_literal: true

module PermissionForge
  module Audit
    # Shared plumbing of the request-context tests: CSRF off, Basic auth and
    # resolvers restored, and a way to swap a controller action for the
    # length of a block.
    module RequestAuditTestHelper
      extend ActiveSupport::Concern

      ROOT = '/permission_forge'

      included do
        setup do
          @old_forgery = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = false
          @old_current_user_resolver = PermissionForge.configuration.current_user_resolver
        end

        teardown do
          ActionController::Base.allow_forgery_protection = @old_forgery
          PermissionForge.configuration.current_user_resolver = @old_current_user_resolver
          PermissionForge.configuration.http_basic_auth_user = nil
          PermissionForge.configuration.http_basic_auth_password = nil
        end
      end

      private

      def sign_in(user)
        PermissionForge.configuration.current_user_resolver = -> { user }
      end

      def enable_basic_auth(user: 'ops-admin', password: 's3cret-pass')
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.http_basic_auth_user = user
        PermissionForge.configuration.http_basic_auth_password = password
      end

      def basic_auth_header(user, password)
        { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }
      end

      # Replaces `controller#action` with `body` (instance_exec'd) for the block.
      def with_action(controller, action, body)
        original = controller.instance_method(action)
        replace_method(controller, action, &body)
        yield
      ensure
        replace_method(controller, action, original)
      end

      # Rails' own request logger reads request.remote_ip at info level and
      # raises IpSpoofAttackError before any controller runs; above info (or
      # with ip_spoofing_check off) the request reaches the engine, whose
      # handling is what these tests are about.
      def with_quiet_request_log
        logger = Rails.logger
        level = logger.level
        logger.level = Logger::WARN
        yield
      ensure
        logger.level = level
      end

      def rename_set(set, name, params: {}, headers: {})
        patch "#{ROOT}/permission_sets/#{set.id}/apply", params: { pf: { set: { name: name } } }.merge(params), headers: headers
      end
    end
  end
end
