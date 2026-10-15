# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Api
    # Field test: unrouted calls under the API mount (an unknown path, a
    # write on the read-only audit events) answered Rails' HTML 404 page.
    class UnmatchedRoutesTest < ActionDispatch::IntegrationTest
      include PermissionForge::Tenancy::TenancyTestHelper

      ROOT = '/permission_forge/api'
      EXPECTED = -> { { 'error' => { 'status' => 404, 'messages' => I18n.t('permission_forge.api.errors.route_not_found') } } }

      setup do
        create_permission_set(name: 'Sales')
        @event = PermissionForge::AuditEvent.order(:id).last
      end

      test 'an unknown path or method under the API answers the JSON 404 envelope' do
        [[:get, '/unknown'], [:get, ''], [:get, '/permission_sets/x/widgets'], [:get, '/a/b.html'], [:put, '/stats'],
         [:post, '/audit_events'], [:patch, "/audit_events/#{@event.uuid}"], [:delete, "/audit_events/#{@event.uuid}"]].each do |verb, path|
          send(verb, "#{ROOT}#{path}", params: { audit_event: { event: 'fake' } }, as: :json)

          assert_response :not_found, "#{verb} #{path}"
          assert_equal 'application/json', response.media_type, "#{verb} #{path}"
          assert_equal EXPECTED.call, response.parsed_body, "#{verb} #{path}"
        end
      end

      test 'it writes no audit event and changes nothing' do
        assert_no_difference -> { PermissionForge::AuditEvent.unscoped.count } do
          post "#{ROOT}/audit_events", params: { audit_event: { event: 'fake' } }, as: :json
          delete "#{ROOT}/audit_events/#{@event.uuid}", as: :json
        end
        assert PermissionForge::AuditEvent.unscoped.exists?(@event.id)
      end

      test 'the real routes still answer' do
        get "#{ROOT}/audit_events/#{@event.uuid}"
        assert_response :ok
        get "#{ROOT}/permission_sets"
        assert_response :ok
      end

      # Field test (round 4, d #35): `/api/permission_sets.xml` answered the
      # JSON list with a 200.
      test 'an extension other than .json reaches no endpoint: the JSON 404 envelope' do
        set = PermissionForge::PermissionSet.order(:id).last
        ['/permission_sets.xml', '/permission_sets.html', '/permission_sets.csv', "/permission_sets/#{set.uuid}.xml",
         "/audit_events/#{@event.uuid}.xml", '/stats.xml', "/permission_sets/#{set.uuid}/resources.yaml"].each do |path|
          get "#{ROOT}#{path}"

          assert_response :not_found, path
          assert_equal 'application/json', response.media_type, path
          assert_equal EXPECTED.call, response.parsed_body, path
        end
        assert_no_difference -> { PermissionForge::PermissionSet.count } do
          post "#{ROOT}/permission_sets.xml", params: { permission_set: { name: 'Via XML' } }, as: :json
        end
        assert_response :not_found
      end

      test '.json and no extension still answer' do
        set = PermissionForge::PermissionSet.order(:id).last
        ['/permission_sets', '/permission_sets.json', "/permission_sets/#{set.uuid}", "/permission_sets/#{set.uuid}.json",
         "/audit_events/#{@event.uuid}.json"].each do |path|
          get "#{ROOT}#{path}"

          assert_response :ok, path
          assert_equal 'application/json', response.media_type, path
        end
      end

      test 'while the API is disabled it is the same bodiless 404 as every API route' do
        PermissionForge.configuration.api_enabled = false

        get "#{ROOT}/unknown"
        assert_response :not_found
        assert_empty response.body
        get "#{ROOT}/permission_sets"
        assert_response :not_found
        assert_empty response.body
      end

      test 'it runs api_auth first: an unauthenticated caller gets the 401, recorded like any API call' do
        PermissionForge.configuration.api_auth = ->(_controller) { false }

        assert_difference -> { PermissionForge::AuditEvent.unscoped.where(event: 'api.auth_failed').count }, 1 do
          get "#{ROOT}/unknown"
        end
        assert_response :unauthorized
      end

      test 'the message follows the request locale' do
        get "#{ROOT}/unknown", headers: { 'Accept-Language' => 'sq' }

        assert_equal I18n.t('permission_forge.api.errors.route_not_found', locale: :sq), response.parsed_body.dig('error', 'messages')
      end

      test 'with no tenant it is refused like every API call' do
        no_tenant!

        get "#{ROOT}/unknown"
        assert_response :forbidden
      end

      test 'outside /api an unknown engine path is still a routing error' do
        assert_raises(ActionController::RoutingError) { get '/permission_forge/apix' }
      end
    end
  end
end
