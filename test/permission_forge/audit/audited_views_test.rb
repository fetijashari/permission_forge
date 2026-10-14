# frozen_string_literal: true

require 'test_helper'
require_relative 'request_audit_test_helper'

module PermissionForge
  module Audit
    # Read-only admin pages that must leave a trace — effective access, the
    # audit tabs and their CSV exports — recorded from the base controller
    # after a successful response, through one registry.
    class AuditedViewsTest < ActionDispatch::IntegrationTest
      include RequestAuditTestHelper

      setup do
        @admin = create_user(name: 'Ada Admin')
        @person = create_user(name: 'Bo Berisha')
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_resource_field(resource: @resource, name: 'email', read_access: true)
        create_permission_set_user(user: @person, permission_set: @set)
        sign_in(@admin)
      end

      test "a person's effective access tab records admin.effective_access_viewed" do
        assert_difference -> { audit_events_for('admin.effective_access_viewed').count }, 1 do
          get "#{ROOT}/people/#{@person.id}", params: { tab: 'effective' }
        end

        assert_response :ok
        assert_audit_event('admin.effective_access_viewed', subject_user_id: @person.id.to_s, actor_id: @admin.id.to_s,
                                                            actor_type: 'user', source: 'admin_ui', category: 'admin')
      end

      test "a person's audit tab records audit.viewed, its CSV audit.exported" do
        get "#{ROOT}/people/#{@person.id}", params: { tab: 'audit' }
        assert_response :ok
        assert_audit_event('audit.viewed', subject_user_id: @person.id.to_s, actor_id: @admin.id.to_s)

        assert_difference -> { audit_events_for('audit.exported').count }, 1 do
          get "#{ROOT}/people/#{@person.id}.csv"
        end
        assert_response :ok
        assert_audit_event('audit.exported', subject_user_id: @person.id.to_s, data: { 'format' => 'csv' })
      end

      test "a Permission Set's audit tab and its CSV export are recorded against the set" do
        get "#{ROOT}/permission_sets/#{@set.id}", params: { tab: 'audit' }
        assert_response :ok
        assert_audit_event('audit.viewed', permission_set_id: @set.id, record_type: 'PermissionForge::PermissionSet',
                                           record_id: @set.id.to_s, actor_id: @admin.id.to_s)

        get "#{ROOT}/permission_sets/#{@set.id}.csv", params: { tab: 'audit', who: @admin.id.to_s, days: '30' }
        assert_response :ok
        assert_audit_event('audit.exported', permission_set_id: @set.id,
                                             data: { 'format' => 'csv', 'filters' => { 'who' => @admin.id.to_s, 'days' => '30' } })
      end

      test "the field drawer's per-person explanation records admin.effective_access_viewed" do
        get "#{ROOT}/permission_sets/#{@set.id}/resources/Customer/fields/email", params: { explain_user_id: @person.id }

        assert_response :ok
        assert_audit_event('admin.effective_access_viewed', subject_user_id: @person.id.to_s, permission_set_id: @set.id,
                                                            data: { 'resource' => 'Customer', 'field' => 'email' })
      end

      test 'other tabs and pages record nothing' do
        assert_no_difference -> { PermissionForge::AuditEvent.where(category: 'admin').count } do
          get "#{ROOT}/people/#{@person.id}"
          get "#{ROOT}/people/#{@person.id}", params: { tab: 'access' }
          get "#{ROOT}/permission_sets/#{@set.id}"
          get "#{ROOT}/permission_sets/#{@set.id}/resources/Customer/fields/email"
          get "#{ROOT}/people"
        end
      end

      test 'an unsuccessful response records nothing' do
        assert_no_difference -> { audit_events_for('admin.effective_access_viewed').count } do
          get "#{ROOT}/people/0", params: { tab: 'effective' }
        rescue ActionController::RoutingError
          nil
        end
      end

      test 'the view event carries the request id and IP' do
        get "#{ROOT}/people/#{@person.id}", params: { tab: 'effective' }, headers: { 'X-Request-Id' => 'view-1', 'REMOTE_ADDR' => '10.9.8.7' }

        assert_audit_event('admin.effective_access_viewed', request_id: 'view-1', ip: '10.9.8.7')
      end

      test 'adding a page is one register call; the first matching entry wins' do
        AuditedViews.register('permission_forge/people#index', 'audit.viewed', payload: ->(c) { { data: { 'q' => c.params[:q].to_s } } })
        AuditedViews.register('permission_forge/people#index', 'audit.exported')

        get "#{ROOT}/people", params: { q: 'bo' }

        assert_audit_event('audit.viewed', data: { 'q' => 'bo' })
        assert_empty audit_events_for('audit.exported').to_a
      ensure
        AuditedViews.unregister('permission_forge/people#index')
      end

      test 'only_if decides whether an entry applies' do
        AuditedViews.register('permission_forge/people#index', 'audit.viewed', only_if: ->(c) { c.params[:q] == 'yes' })

        assert_no_difference(-> { audit_events_for('audit.viewed').count }) { get "#{ROOT}/people", params: { q: 'no' } }
        assert_difference(-> { audit_events_for('audit.viewed').count }, 1) { get "#{ROOT}/people", params: { q: 'yes' } }
      ensure
        AuditedViews.unregister('permission_forge/people#index')
      end

      test 'register refuses an event that is not in the catalogue or is a runtime event' do
        assert_raises(EventCatalog::UnknownEventError) { AuditedViews.register('permission_forge/people#index', 'nope.viewed') }
        assert_raises(ArgumentError) { AuditedViews.register('permission_forge/people#index', 'access.denied') }
        assert_empty AuditedViews.entries_for('permission_forge/people#index')
      end

      test 'the default registry names the effective access views, audit tabs and exports' do
        assert_equal %w[admin.effective_access_viewed audit.exported audit.viewed],
                     AuditedViews.entries.values.flatten.map(&:event).uniq.sort
      end

      # ---- review round 1 ---------------------------------------------------------------

      test 'a CSV negotiated through the Accept header is recorded as an export' do
        assert_difference -> { audit_events_for('audit.exported').count }, 1 do
          get "#{ROOT}/people/#{@person.id}", headers: { 'Accept' => 'application/json, text/csv' }
        end
        assert_equal 'text/csv', response.media_type

        get "#{ROOT}/permission_sets/#{@set.id}", params: { tab: 'audit' }, headers: { 'Accept' => 'text/csv' }
        assert_equal 'text/csv', response.media_type
        assert_audit_event('audit.exported', permission_set_id: @set.id)
      end

      test 'an HTML page asked for with .csv-looking Accept but rendered as HTML is a view' do
        get "#{ROOT}/people/#{@person.id}", params: { tab: 'audit' }, headers: { 'Accept' => 'text/html' }

        assert_equal 'text/html', response.media_type
        assert_audit_event('audit.viewed', subject_user_id: @person.id.to_s)
      end

      test 'a HEAD request records nothing' do
        assert_no_difference -> { PermissionForge::AuditEvent.where(category: 'admin').count } do
          head "#{ROOT}/people/#{@person.id}", params: { tab: 'effective' }
          head "#{ROOT}/people/#{@person.id}.csv"
        end
      end

      test 'explain_user_id sent as an array is still recorded, with its first id' do
        get "#{ROOT}/permission_sets/#{@set.id}/resources/Customer/fields/email", params: { explain_user_id: [@person.id.to_s] }

        assert_response :ok
        assert_audit_event('admin.effective_access_viewed', subject_user_id: @person.id.to_s, data: { 'field' => 'email' })
      end

      test 'reading the audit log through the API records audit.viewed with its filters' do
        get "#{ROOT}/api/audit_events", params: { event: 'permission_set.created', actor_id: @admin.id.to_s }
        assert_response :ok
        assert_audit_event('audit.viewed', source: 'api',
                                           data: { 'scope' => 'api', 'filters' => { 'event' => 'permission_set.created',
                                                                                    'actor_id' => @admin.id.to_s } })

        shown = PermissionForge::AuditEvent.order(:id).first
        get "#{ROOT}/api/audit_events/#{shown.uuid}"
        assert_response :ok
        assert_audit_event('audit.viewed', source: 'api', data: { 'identifier' => shown.uuid })
      end
    end
  end
end
