# frozen_string_literal: true

require 'test_helper'
require 'rake'
require_relative 'table_ledger'

module PermissionForge
  module AuditIntegration
    # Shared plumbing of the audit integration suite: who acts (a signed-in
    # admin, HTTP Basic, an API token named by audit_actor_resolver), the
    # events a block wrote, and a store that fails on purpose.
    module IntegrationSupport
      extend ActiveSupport::Concern
      include TableLedger::Assertions

      ROOT = '/permission_forge'
      REASON = 'TCK-4711 access review'
      ADMIN_NAME = 'Ada Admin'
      BASIC_USER = 'ops-admin'
      BASIC_PASSWORD = 's3cret-pass'
      API_ACTOR = { type: 'api', id: 'tok-7', label: 'CI deploy token' }.freeze

      # The expected [actor_type, actor_id, actor_label] per way of acting;
      # :signed_in is filled in with the admin's id.
      ACTORS = {
        signed_in: ['user', :admin, ADMIN_NAME],
        basic_auth: ['basic_auth', nil, BASIC_USER],
        api_token: ['api', 'tok-7', 'CI deploy token']
      }.freeze

      READ_ONLY_VERBS = %w[GET HEAD].freeze

      # [verb, path, endpoint] of every engine route that can change something.
      def self.engine_write_routes
        PermissionForge::Engine.routes.routes.flat_map do |route|
          endpoint = "#{route.defaults[:controller]}##{route.defaults[:action]}"
          path = route.path.spec.to_s.delete_suffix('(.:format)')
          write_verbs(route).map { |verb| [verb, path, endpoint] }
        end
      end

      # A route drawn with `via: [:get, :post]` has the verb "GET|POST".
      def self.write_verbs(route)
        route.verb.to_s.split('|').reject { |verb| verb.empty? || READ_ONLY_VERBS.include?(verb) }
      end

      RAKE_FILES = PermissionForge::Engine.root.glob('lib/tasks/*.rake').sort.freeze

      # One Rake application with the gem's task files, built once per process.
      def self.rake_application
        @rake_application ||= begin
          previous = Rake.application
          app = Rake.application = Rake::Application.new
          Rake::Task.define_task(:environment)
          RAKE_FILES.each { |file| load file.to_s }
          Rake.application = previous
          app
        end
      end

      included do
        setup do
          @old_forgery = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = false
          @old_current_user_resolver = PermissionForge.configuration.current_user_resolver
          @auth_headers = {}
        end

        teardown do
          ActionController::Base.allow_forgery_protection = @old_forgery
          PermissionForge.configuration.current_user_resolver = @old_current_user_resolver
          PermissionForge.configuration.http_basic_auth_user = nil
          PermissionForge.configuration.http_basic_auth_password = nil
        end
      end

      private

      # --- who acts ---------------------------------------------------------------

      def act_as(mode, admin: @admin)
        case mode
        when :signed_in then sign_in(admin)
        when :basic_auth then basic_auth!
        when :api_token then api_token!
        else raise ArgumentError, "unknown mode #{mode.inspect}"
        end
      end

      def sign_in(user)
        PermissionForge.configuration.current_user_resolver = -> { user }
      end

      def basic_auth!
        PermissionForge.configuration.current_user_resolver = -> {}
        PermissionForge.configuration.http_basic_auth_enabled = true
        PermissionForge.configuration.http_basic_auth_user = BASIC_USER
        PermissionForge.configuration.http_basic_auth_password = BASIC_PASSWORD
        @auth_headers = { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials(BASIC_USER, BASIC_PASSWORD) }
      end

      def api_token!
        PermissionForge.configuration.current_user_resolver = -> {}
        PermissionForge.configuration.audit_actor_resolver = ->(_controller) { API_ACTOR }
      end

      def expected_actor(mode)
        type, id, label = ACTORS.fetch(mode)
        [type, id == :admin ? @admin.id.to_s : id, label]
      end

      # --- requests ---------------------------------------------------------------

      # An admin UI request with the reason field and the mode's credentials;
      # fails unless the response is a success or a redirect. The events it
      # wrote are kept in @request_events.
      def admin_request(verb, path, params = {})
        @request_events = ledger_events do
          send(verb, "#{ROOT}#{path}", params: params.merge(reason: REASON), headers: @auth_headers)
        end
        assert_success_or_redirect(verb, path)
      end

      def api_request(verb, path, params = {})
        @request_events = ledger_events do
          send(verb, "#{ROOT}/api#{path}", params: params.merge(reason: REASON), headers: @auth_headers, as: :json)
        end
        assert_success_or_redirect(verb, path)
      end

      def assert_success_or_redirect(verb, path)
        assert_includes 200..399, response.status, "#{verb.upcase} #{path} answered #{response.status}: #{response.body.to_s[0, 400]}"
      end

      # --- events -----------------------------------------------------------------

      # The audit events (every tenant) written inside the block, oldest first.
      def events_during
        baseline = PermissionForge::AuditEvent.unscoped.maximum(:id) || 0
        yield
        PermissionForge::AuditEvent.unscoped.where(PermissionForge::AuditEvent.arel_table[:id].gt(baseline)).order(:id).to_a
      end

      def recorded_names(events) = events.map(&:event).uniq.sort

      # Makes every write of an audit event named in `names` (all when nil)
      # fail for the block, as a full disk or a revoked INSERT grant would.
      def failing_store(names = nil)
        model = PermissionForge::AuditEvent
        model.singleton_class.alias_method(:pf_t11_store!, :store!)
        model.define_singleton_method(:store!) do |attributes|
          raise ActiveRecord::StatementInvalid, 'audit store down' if names.nil? || names.include?(attributes[:event])

          pf_t11_store!(attributes)
        end
        yield
      ensure
        replace_method(model.singleton_class, :store!, model.singleton_class.instance_method(:pf_t11_store!))
        model.singleton_class.remove_method(:pf_t11_store!)
      end

      # Rails.error reports made inside the block.
      def error_reports
        reports = []
        subscriber = Object.new
        subscriber.define_singleton_method(:report) { |error, **context| reports << [error, context] }
        Rails.error.subscribe(subscriber)
        yield
        reports
      ensure
        Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
      end

      # Runs a gem rake task (output captured; a task that exits is stopped there).
      def run_rake_task(name)
        previous = Rake.application
        Rake.application = IntegrationSupport.rake_application
        Rake::Task[name].reenable
        capture_io do
          Rake::Task[name].invoke
        rescue SystemExit
          nil # report tasks exit 1 when they find something
        end
      ensure
        Rake.application = previous
      end

      def with_env(values)
        saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
        values.each { |key, value| ENV[key] = value }
        yield
      ensure
        saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end

      def with_config(option, value)
        config = PermissionForge.configuration
        previous = config.public_send(option)
        config.public_send(:"#{option}=", value)
        yield
      ensure
        config.public_send(:"#{option}=", previous)
      end
    end
  end
end
