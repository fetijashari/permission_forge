# frozen_string_literal: true

require 'test_helper'
require_relative '../cache/failing_store'

module PermissionForge
  module Api
    # A single assignment created or revoked over the API answers the cache
    # outcome the bulk endpoint answers (`meta.cache`, Cache::Outcome): a
    # client learns that the old permissions may stay in use when the store
    # did not confirm (R2 review, P1-2).
    class AssignmentCacheOutcomeApiTest < ActionDispatch::IntegrationTest
      setup do
        @store = PermissionForge::Cache::FailingStore.new
        PermissionForge.configuration.cache_backend = @store
        PermissionForge.configuration.reset_cache_store!
        @set = create_permission_set(name: 'Sales')
        @ana = create_user(name: 'Ana')
        @path = "/permission_forge/api/permission_sets/#{@set.uuid}/users"
      end

      teardown do
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      def cache = JSON.parse(response.body).dig('meta', 'cache')

      test 'a single grant answers the cache outcome' do
        post @path, params: { user_id: @ana.id }

        assert_response :created
        assert_equal({ 'confirmed' => true, 'process_local' => true, 'unconfirmed' => 0, 'in_request' => true }, cache)
      end

      test 'a single revoke with the store down answers that nothing was confirmed' do
        assignment = create_permission_set_user(user: @ana, permission_set: @set)
        @store.down!

        delete "#{@path}/#{assignment.uuid}"

        assert_response :ok
        assert_not PermissionForge::PermissionSetUser.exists?(assignment.id)
        assert_equal assignment.uuid, JSON.parse(response.body).dig('data', 'uuid')
        assert_equal({ 'confirmed' => false, 'process_local' => true, 'unconfirmed' => 1, 'in_request' => true }, cache)
      end

      test 'a single grant with the store down answers that nothing was confirmed' do
        @store.down!

        post @path, params: { user_id: @ana.id }

        assert_response :created
        assert_equal false, cache['confirmed']
      end
    end
  end
end
