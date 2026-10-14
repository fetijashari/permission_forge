# frozen_string_literal: true

require 'test_helper'
require_relative 'shipped_api_authorization'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Security
    # config.user_list_resolver is the boundary of the people an admin (or an
    # API caller) can reach, not just the list the pickers show. Here the
    # host narrows it to the current tenant's users: a tenant-A admin must
    # not view, assign, add to a group, bulk-assign, explain or erase Bob,
    # who exists only in tenant B — whatever id the request names.
    class PeopleResolverBoundaryTest < ActionDispatch::IntegrationTest
      include ShippedApiAuthorization

      include PermissionForge::Tenancy::TenancyTestHelper

      ROOT = '/permission_forge'

      setup do
        @old_forgery = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = false
        @tenant_a = Account.create!(name: 'Tenant A')
        @tenant_b = Account.create!(name: 'Tenant B')
        @ana = create_user(name: 'Ana In-A', email: 'ana@a.test', account_id: @tenant_a.id)
        @bob = create_user(name: 'Bob Only-In-B', email: 'bob@b.test', account_id: @tenant_b.id)
        within(@tenant_b) do
          @set_b = create_permission_set(name: 'Bravoset')
          create_resource(permission_set: @set_b, name: 'Customer')
          @assignment_b = create_permission_set_user(user: @bob, permission_set: @set_b)
        end
        within(@tenant_a) do
          @set_a = create_permission_set(name: 'Alphaset')
          @resource_a = create_resource(permission_set: @set_a, name: 'Customer', read_access: true)
          create_resource_field(resource: @resource_a, name: 'email', read_access: true)
          @group_a = create_permission_set_group(name: 'Alphagroup')
        end
        PermissionForge.configuration.user_list_resolver = -> { User.where(account_id: ActsAsTenant.current_tenant&.id) }
        ActsAsTenant.test_tenant = @tenant_a
      end

      teardown do
        ActionController::Base.allow_forgery_protection = @old_forgery
      end

      # --- one lookup ---------------------------------------------------------

      test 'PeopleDirectory#find resolves within the resolver relation' do
        directory = PermissionForge::Admin::PeopleDirectory.new

        assert_equal @ana, directory.find(@ana.id)
        assert_equal @ana, directory.find(@ana.id.to_s)
        assert_nil directory.find(@bob.id)
        assert_nil directory.find("#{@ana.id}abc")
        assert_nil directory.find({ 'id' => @ana.id })
        assert_nil directory.find(nil)
        assert_equal [@ana], directory.find_all([@ana.id, @bob.id, '', 'x'])
      end

      test 'PeopleDirectory#find resolves within an array resolver' do
        PermissionForge.configuration.user_list_resolver = -> { [@ana] }
        directory = PermissionForge::Admin::PeopleDirectory.new

        assert_equal @ana, directory.find(@ana.id.to_s)
        assert_nil directory.find(@bob.id)
      end

      test 'an array resolver is evaluated once per bulk preview, however many lines are pasted' do
        calls = 0
        ana = @ana
        PermissionForge.configuration.user_list_resolver = lambda {
          calls += 1
          [ana]
        }

        post "#{ROOT}/permission_sets/#{@set_a.id}/bulk_assignment/preview",
             params: { identifiers: "ana@a.test\nbob@b.test\nAna In-A\nnobody\nx@y.z", user_ids: [@ana.id, @bob.id] }

        assert_response :ok
        assert_equal 1, calls
      end

      # --- HTML admin -----------------------------------------------------------

      test 'the person page of someone outside the resolver is not found' do
        assert_raises(ActionController::RoutingError) { get "#{ROOT}/people/#{@bob.id}" }

        get "#{ROOT}/people/#{@ana.id}"
        assert_response :ok
      end

      test 'erasure of someone outside the resolver is refused and changes nothing' do
        labelled = -> { PermissionForge::AuditEvent.unscoped.where(subject_user_id: @bob.id.to_s).where.not(record_label: nil).count }
        before = labelled.call

        assert_raises(ActionController::RoutingError) do
          post "#{ROOT}/people/#{@bob.id}/erasure", params: { confirmation: 'Bob Only-In-B' }
        end

        assert_equal before, labelled.call
        within(@tenant_b) { assert PermissionForge::PermissionSetUser.exists?(@assignment_b.id) }
      end

      test 'the assign form does not accept someone outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetUser.unscoped.count } do
          post "#{ROOT}/assignments", params: { user_id: @bob.id, set_ids: [@set_a.id] }
        end
        assert_response :unprocessable_entity
      end

      test 'restore (undo of a removal) does not accept someone outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetUser.unscoped.count } do
          assert_raises(ActionController::RoutingError) do
            post "#{ROOT}/assignments/restore", params: { permission_set_id: @set_a.id, user_id: @bob.id }
          end
        end
      end

      test 'a group does not take a member outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetGroupUser.unscoped.count } do
          post "#{ROOT}/groups/#{@group_a.id}/members", params: { user_id: @bob.id }
        end
        assert_equal I18n.t('permission_forge.flash.permission_set_group_users.user_not_found'), flash[:alert]
      end

      test 'bulk assignment ignores picked and pasted people outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetUser.unscoped.count } do
          post "#{ROOT}/permission_sets/#{@set_a.id}/bulk_assignment",
               params: { user_ids: [@bob.id], identifiers: "bob@b.test\nBob Only-In-B" }
        end
        assert_response :unprocessable_entity
        assert_includes response.body, 'bob@b.test' # listed under "not found"

        post "#{ROOT}/permission_sets/#{@set_a.id}/bulk_assignment", params: { identifiers: 'ana@a.test' }
        assert PermissionForge::PermissionSetUser.exists?(user_id: @ana.id, permission_set_id: @set_a.id)
      end

      test 'bulk revoke does not reach someone outside the resolver' do
        within(@tenant_a) { create_permission_set_user(user: @bob, permission_set: @set_a) }

        delete "#{ROOT}/permission_sets/#{@set_a.id}/bulk_assignment/revoke", params: { user_ids: [@bob.id] }

        assert PermissionForge::PermissionSetUser.exists?(user_id: @bob.id, permission_set_id: @set_a.id)
      end

      test 'the field drawer does not explain the access of someone outside the resolver' do
        within(@tenant_a) { create_permission_set_user(user: @bob, permission_set: @set_a) }

        get "#{ROOT}/permission_sets/#{@set_a.id}/resources/Customer/fields/email", params: { explain_user_id: @bob.id }

        assert_response :ok
        assert_not_includes response.body, 'Bob Only-In-B'
      end

      # --- JSON API ---------------------------------------------------------------

      test 'the API does not assign someone outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetUser.unscoped.count } do
          post "#{ROOT}/api/permission_sets/#{@set_a.uuid}/users", params: { user_id: @bob.id }
        end
        assert_response :not_found

        post "#{ROOT}/api/permission_sets/#{@set_a.uuid}/users", params: { user_id: @ana.id }
        assert_response :created
      end

      test 'the API does not add a group member outside the resolver' do
        assert_no_difference -> { PermissionForge::PermissionSetGroupUser.unscoped.count } do
          post "#{ROOT}/api/permission_set_groups/#{@group_a.uuid}/users", params: { user_id: @bob.id }
        end
        assert_response :not_found
      end

      test 'API bulk assignment skips people outside the resolver' do
        post "#{ROOT}/api/permission_sets/#{@set_a.uuid}/users/bulk",
             params: { user_ids: [@bob.id, @ana.id], bulk_action: 'assign' }

        assert_response :ok
        assert_equal 1, response.parsed_body.dig('data', 'assigned')
        assert_not PermissionForge::PermissionSetUser.unscoped.exists?(user_id: @bob.id, permission_set_id: @set_a.id)
      end
    end
  end
end
