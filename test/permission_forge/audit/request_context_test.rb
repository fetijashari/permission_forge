# frozen_string_literal: true

require 'test_helper'
require_relative 'request_audit_test_helper'

module PermissionForge
  module Audit
    # The around-action of the admin UI and API base controllers: who acts,
    # from where, which request, why — for every event of the request, and
    # nothing of it left behind afterwards.
    class RequestContextTest < ActionDispatch::IntegrationTest
      include RequestAuditTestHelper

      setup do
        @set = create_permission_set(name: 'Sales rep')
        @admin = create_user(name: 'Ada Admin', email: 'ada@acme.test')
      end

      # ---- actor matrix: admin UI ------------------------------------------------

      test 'admin UI with a host sign-in records the signed-in user' do
        sign_in(@admin)

        rename_set(@set, 'Renamed')

        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: @admin.id.to_s,
                                                     actor_label: 'Ada Admin', source: 'admin_ui')
      end

      test 'admin UI under HTTP Basic records the configured username, no id' do
        enable_basic_auth(user: 'ops-admin')

        rename_set(@set, 'Renamed', headers: basic_auth_header('ops-admin', 's3cret-pass'))

        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', actor_type: 'basic_auth', actor_id: nil,
                                                     actor_label: 'ops-admin', source: 'admin_ui')
      end

      test 'admin UI under HTTP Basic with a host sign-in records the signed-in user' do
        enable_basic_auth
        sign_in(@admin)

        rename_set(@set, 'Renamed', headers: basic_auth_header('ops-admin', 's3cret-pass'))

        assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: @admin.id.to_s, source: 'admin_ui')
      end

      test 'admin UI with nobody signed in records an unknown actor' do
        rename_set(@set, 'Renamed')

        assert_audit_event('permission_set.updated', actor_type: 'unknown', actor_id: nil, actor_label: nil, source: 'admin_ui')
      end

      test 'audit_actor_resolver wins over the signed-in user and receives the controller' do
        other = create_user(name: 'Root Admin')
        seen = nil
        sign_in(@admin)
        PermissionForge.configuration.audit_actor_resolver = lambda { |controller|
          seen = controller
          other
        }

        rename_set(@set, 'Renamed')

        assert_kind_of PermissionForge::ApplicationController, seen
        assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: other.id.to_s, actor_label: 'Root Admin')
      end

      test 'audit_actor_resolver may return a Hash or an Actor' do
        PermissionForge.configuration.audit_actor_resolver = ->(_c) { { type: 'system', label: 'SSO bridge' } }
        rename_set(@set, 'One')
        assert_audit_event('permission_set.updated', actor_type: 'system', actor_label: 'SSO bridge')

        PermissionForge.configuration.audit_actor_resolver = ->(_c) { Actor.new(type: 'user', id: 'u-9', label: 'Nine') }
        rename_set(@set, 'Two')
        assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: 'u-9', actor_label: 'Nine')
      end

      test 'audit_actor_resolver returning nil falls back to the signed-in user' do
        sign_in(@admin)
        PermissionForge.configuration.audit_actor_resolver = ->(_c) {}

        rename_set(@set, 'Renamed')

        assert_audit_event('permission_set.updated', actor_type: 'user', actor_id: @admin.id.to_s)
      end

      test 'a raising audit_actor_resolver does not break the request: actor unknown, failure reported' do
        sign_in(@admin)
        PermissionForge.configuration.audit_actor_resolver = ->(_c) { raise 'resolver down' }
        reported = capture_reports do
          rename_set(@set, 'Renamed')
        end

        assert_response :redirect
        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', actor_type: 'unknown', actor_id: nil)
        assert(reported.any? { |error| error.message == 'resolver down' }, 'the failure is reported')
      end

      test 'a raising current_user_resolver does not break the request: actor unknown, failure reported' do
        PermissionForge.configuration.current_user_resolver = -> { raise 'session store down' }
        reported = capture_reports { rename_set(@set, 'Renamed') }

        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', actor_type: 'unknown')
        assert(reported.any? { |error| error.message == 'session store down' })
      end

      test 'a resolver answer that is not an actor counts as a failure: actor unknown' do
        PermissionForge.configuration.audit_actor_resolver = ->(_c) { { type: 'superuser', label: 'x' } }
        capture_reports { rename_set(@set, 'Renamed') }

        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', actor_type: 'unknown')
      end

      test 'an admin edit by nobody, or under Basic auth, keeps the previous updated_by; a signed-in edit moves it' do
        PermissionForge.configuration.audit_trail_enabled = true
        @set.update_columns(created_by_id: @admin.id, updated_by_id: @admin.id)

        rename_set(@set, 'By nobody')
        assert_equal ['By nobody', @admin.id], [@set.reload.name, @set.updated_by_id]

        enable_basic_auth
        rename_set(@set, 'By Basic', headers: basic_auth_header('ops-admin', 's3cret-pass'))
        assert_equal ['By Basic', @admin.id], [@set.reload.name, @set.updated_by_id]

        other = create_user(name: 'Bo')
        sign_in(other)
        rename_set(@set, 'By Bo', headers: basic_auth_header('ops-admin', 's3cret-pass'))
        assert_equal ['By Bo', other.id], [@set.reload.name, @set.updated_by_id]
      ensure
        PermissionForge.configuration.audit_trail_enabled = false
      end

      # ---- actor matrix: API -----------------------------------------------------

      test 'API with a token principal named by audit_actor_resolver' do
        PermissionForge.configuration.api_auth = ->(c) { c.request.headers['Authorization'] == 'Bearer t0k' }
        PermissionForge.configuration.audit_actor_resolver = lambda { |c|
          { type: 'api', id: 'token-7', label: 'CI deploy token' } if c.request.headers['Authorization'] == 'Bearer t0k'
        }

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'From API' } },
                                            headers: { 'Authorization' => 'Bearer t0k' }

        assert_response :created
        assert_audit_event('permission_set.created', actor_type: 'api', actor_id: 'token-7',
                                                     actor_label: 'CI deploy token', source: 'api')
      end

      test 'API with a signed-in host user records that user' do
        sign_in(@admin)

        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'From API' } }

        assert_response :created
        assert_audit_event('permission_set.created', actor_type: 'user', actor_id: @admin.id.to_s,
                                                     actor_label: 'Ada Admin', source: 'api')
      end

      test 'API with nobody identified records an anonymous API client' do
        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'From API' } }

        assert_response :created
        assert_audit_event('permission_set.created', actor_type: 'api', actor_id: nil,
                                                     actor_label: ActorResolver::API_CLIENT_LABEL, source: 'api')
      end

      # ---- request id, IP ------------------------------------------------------------

      test 'request id and remote IP are recorded' do
        rename_set(@set, 'Renamed', headers: { 'X-Request-Id' => 'req-abc-123', 'REMOTE_ADDR' => '10.1.2.3' })

        assert_audit_event('permission_set.updated', request_id: 'req-abc-123', ip: '10.1.2.3')
      end

      test 'audit_request_context overrides the defaults; a key it returns as nil stores nothing' do
        PermissionForge.configuration.audit_request_context = ->(c) { { request_id: "edge-#{c.request.request_id}", ip: nil } }

        rename_set(@set, 'Renamed', headers: { 'X-Request-Id' => 'r1', 'REMOTE_ADDR' => '10.1.2.3' })

        assert_audit_event('permission_set.updated', request_id: 'edge-r1', ip: nil)
      end

      test 'a raising audit_request_context falls back to the defaults' do
        PermissionForge.configuration.audit_request_context = ->(_c) { raise 'ctx down' }
        capture_reports { rename_set(@set, 'Renamed', headers: { 'X-Request-Id' => 'r2' }) }

        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', request_id: 'r2')
      end

      # ---- correlation id ----------------------------------------------------------

      test 'every event of one mutating request shares one correlation id, a new one per request' do
        resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_resource_field(resource: resource, name: 'email', read_access: true)

        delete "#{ROOT}/permission_sets/#{@set.id}"

        events = PermissionForge::AuditEvent.where(permission_set_id: @set.id, event: %w[permission_set.destroyed resource.destroyed
                                                                                         resource_field.destroyed])
        assert_operator events.count, :>=, 3
        assert_equal 1, events.distinct.count(:correlation_id)

        other = create_permission_set(name: 'Other')
        delete "#{ROOT}/permission_sets/#{other.id}"
        refute_equal events.first.correlation_id, assert_audit_event('permission_set.destroyed', record_id: other.id.to_s).correlation_id
      end

      test 'a mutating request runs inside one correlate block; a GET does not' do
        seen = {}
        capture = lambda { |key|
          lambda {
            seen[key] = Context.current.dup
            head :ok
          }
        }
        with_action(PermissionForge::PeopleController, :index, capture.call(:get)) { get "#{ROOT}/people" }
        assert_nil seen[:get][:correlation_id]
        assert_equal 'admin_ui', seen[:get][:source]

        with_action(PermissionForge::PermissionSetsController, :apply, capture.call(:patch)) { rename_set(@set, 'x') }
        assert seen[:patch][:correlation_id].present?
      end

      # ---- reason --------------------------------------------------------------------

      test 'the reason param of a mutating request reaches its events, stripped' do
        rename_set(@set, 'Renamed', params: { reason: "  TCK-42 quarterly review \n" })

        assert_audit_event('permission_set.updated', reason: 'TCK-42 quarterly review')
      end

      test 'a reason in a JSON body reaches API events' do
        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'From API' }, reason: 'CHG-9' }.to_json,
                                            headers: { 'CONTENT_TYPE' => 'application/json' }

        assert_response :created
        assert_audit_event('permission_set.created', reason: 'CHG-9')
      end

      test 'the reason is capped at 255 characters' do
        rename_set(@set, 'Renamed', params: { reason: 'é' * 400 })

        assert_equal 'é' * 255, assert_audit_event('permission_set.updated').reason
      end

      test 'a blank reason, or one that is not a string, stores nothing' do
        rename_set(@set, 'One', params: { reason: '   ' })
        assert_audit_event('permission_set.updated', reason: nil)

        rename_set(@set, 'Two', params: { reason: { nested: 'x' } })
        assert_audit_event('permission_set.updated', reason: nil)

        rename_set(@set, 'Three', params: { reason: %w[a b] })
        assert_audit_event('permission_set.updated', reason: nil)
      end

      test 'a GET does not read a reason' do
        seen = :unset
        action = lambda {
          seen = Context[:reason]
          head :ok
        }
        with_action(PermissionForge::PeopleController, :index, action) { get "#{ROOT}/people", params: { reason: 'not for reads' } }
        assert_nil seen
      end

      # ---- spoofing ------------------------------------------------------------------

      test 'the actor cannot be named through params or headers' do
        sign_in(@admin)
        spoof = { actor: 'Mallory', actor_id: '999', actor_type: 'system', actor_label: 'Mallory', user_id: '999',
                  source: 'rake', audit: { actor: 'Mallory' } }
        headers = { 'X-PF-Actor' => 'Mallory', 'X-Actor-Id' => '999', 'X-Audit-Source' => 'rake', 'X-User' => 'Mallory' }

        rename_set(@set, 'Renamed', params: spoof, headers: headers)

        event = assert_audit_event('permission_set.updated')
        assert_equal ['user', @admin.id.to_s, 'Ada Admin', 'admin_ui'], [event.actor_type, event.actor_id, event.actor_label, event.source]
      end

      test 'a Basic Authorization header is not an actor when Basic auth is off' do
        rename_set(@set, 'Renamed', headers: basic_auth_header('Mallory', 'whatever'))

        assert_audit_event('permission_set.updated', actor_type: 'unknown', actor_label: nil)
      end

      test 'API: params and headers cannot name the actor either' do
        post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'From API' }, actor: 'Mallory', actor_id: '1' },
                                            headers: { 'X-PF-Actor' => 'Mallory' }

        assert_audit_event('permission_set.created', actor_type: 'api', actor_id: nil, actor_label: ActorResolver::API_CLIENT_LABEL)
      end

      # ---- nothing left behind --------------------------------------------------------

      test 'no context is left after a request' do
        sign_in(@admin)
        rename_set(@set, 'Renamed', params: { reason: 'r' })

        assert_equal({}, Context.current)
      end

      test 'the next request does not inherit actor, reason or correlation id' do
        sign_in(@admin)
        rename_set(@set, 'First', params: { reason: 'first reason' })
        first = assert_audit_event('permission_set.updated', reason: 'first reason')

        PermissionForge.configuration.current_user_resolver = -> {}
        rename_set(@set, 'Second')
        second = assert_audit_event('permission_set.updated', record_id: @set.id.to_s, data: { 'changes' => { 'name' => %w[First Second] } })

        assert_equal ['unknown', nil, nil], [second.actor_type, second.actor_id, second.reason]
        refute_equal first.correlation_id, second.correlation_id
      end

      test 'an exception inside the action leaves no context behind' do
        sign_in(@admin)
        inside = nil
        boom = lambda {
          inside = Context.current.dup
          raise ArgumentError, 'boom inside the action'
        }

        with_action(PermissionForge::PermissionSetsController, :apply, boom) do
          rename_set(@set, 'x', params: { reason: 'r' })
        rescue ArgumentError
          nil # raised through in the test environment
        end

        assert_equal 'r', inside[:reason]
        assert inside[:correlation_id].present?
        assert_equal({}, Context.current)

        PermissionForge.configuration.current_user_resolver = -> {}
        rename_set(@set, 'After')
        assert_audit_event('permission_set.updated', actor_type: 'unknown', reason: nil)
      end

      test 'API: an exception inside the action leaves no context behind' do
        with_action(PermissionForge::Api::PermissionSetsController, :create, -> { raise ArgumentError, 'boom' }) do
          post "#{ROOT}/api/permission_sets", params: { permission_set: { name: 'x' }, reason: 'r' }
        rescue ArgumentError
          nil
        end

        assert_equal({}, Context.current)
      end

      # ---- review round 1 ---------------------------------------------------------------

      test 'contradicting Client-IP / X-Forwarded-For never fail a page: the peer address is stored' do
        spoof = { 'X-Forwarded-For' => '6.6.6.6', 'Client-IP' => '7.7.7.7', 'REMOTE_ADDR' => '10.4.4.4' }

        with_quiet_request_log do
          get "#{ROOT}/people", headers: spoof
          assert_response :ok

          rename_set(@set, 'Renamed', headers: spoof)
        end
        assert_equal 'Renamed', @set.reload.name
        assert_audit_event('permission_set.updated', ip: '10.4.4.4')
      end

      test 'a NUL byte or line breaks in the reason are cleaned, not a failed change' do
        patch "#{ROOT}/api/permission_sets/#{@set.uuid}", params: { permission_set: { name: 'N' }, reason: "a\u0000b\nc\td\e[0m" }

        assert_response :ok
        assert_equal 'N', @set.reload.name
        assert_audit_event('permission_set.updated', reason: 'ab c d[0m')
      end

      test 'an actor the host names around the request (with_audit_actor) wins over the resolved one' do
        sign_in(@admin)
        ops = create_user(name: 'Ops Bot')

        PermissionForge.with_audit_actor(user: ops) { rename_set(@set, 'Renamed') }

        assert_audit_event('permission_set.updated', actor_id: ops.id.to_s, actor_label: 'Ops Bot', source: 'admin_ui')
      end

      private

      # Errors handed to Rails.error during the block.
      def capture_reports
        reported = []
        subscriber = Object.new
        subscriber.define_singleton_method(:report) { |error, **| reported << error }
        Rails.error.subscribe(subscriber)
        yield
        reported
      ensure
        Rails.error.unsubscribe(subscriber) if Rails.error.respond_to?(:unsubscribe)
      end
    end
  end
end
