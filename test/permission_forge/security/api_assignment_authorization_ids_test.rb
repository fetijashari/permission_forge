# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'

module PermissionForge
  module Security
    # config.api_assignment_authorization gets the people concerned as an
    # Array in the user model's primary-key type (Integers here) on every
    # endpoint, so the documented self-assignment check
    # `!user_ids.include?(current_user.id)` holds whatever the request sent.
    class ApiAssignmentAuthorizationIdsTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      ROOT = '/permission_forge/api'

      setup do
        @set = create_permission_set
        @group = create_permission_set_group
        @user = create_user
        @other = create_user
        @seen = seen = []
        PermissionForge.configuration.api_assignment_authorization = lambda { |_controller, _target, user_ids|
          seen << user_ids
          true
        }
      end

      test 'create passes the id as an Integer' do
        post "#{ROOT}/permission_sets/#{@set.uuid}/users", params: { user_id: @user.id.to_s }

        assert_response :created
        assert_equal [[@user.id]], @seen
      end

      test 'destroy passes the id as an Integer' do
        assignment = create_permission_set_user(user: @user, permission_set: @set)

        delete "#{ROOT}/permission_sets/#{@set.uuid}/users/#{assignment.uuid}"

        assert_response :ok
        assert_equal [[@user.id]], @seen
      end

      test 'bulk passes Integers, without blanks, junk or repeats' do
        post "#{ROOT}/permission_sets/#{@set.uuid}/users/bulk",
             params: { user_ids: [@user.id.to_s, @other.id.to_s, '', @user.id.to_s, 'x'], bulk_action: 'assign' }

        assert_response :ok
        assert_equal [[@user.id, @other.id]], @seen
      end

      test 'bulk with one id that is not a list still passes an Array' do
        post "#{ROOT}/permission_sets/#{@set.uuid}/users/bulk", params: { user_ids: @user.id.to_s, bulk_action: 'assign' }

        assert_equal [[@user.id]], @seen
      end

      test 'group membership create and destroy pass Integers' do
        post "#{ROOT}/permission_set_groups/#{@group.uuid}/users", params: { user_id: @user.id.to_s }
        assert_response :created
        membership = PermissionForge::PermissionSetGroupUser.find_by!(user_id: @user.id)
        delete "#{ROOT}/permission_set_groups/#{@group.uuid}/users/#{membership.uuid}"
        assert_response :no_content

        assert_equal [[@user.id], [@user.id]], @seen
      end

      test 'a self-assignment check written against Integers refuses a String id' do
        me = @user
        PermissionForge.configuration.api_assignment_authorization = ->(_c, _t, user_ids) { !user_ids.include?(me.id) }

        post "#{ROOT}/permission_sets/#{@set.uuid}/users", params: { user_id: me.id.to_s }

        assert_response :forbidden
      end
    end
  end
end
