# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Exercises the ResponseRenderer branches that the happy-path controller
    # tests never hit: render_not_found (via find_host_user) and the failure
    # branch of save_and_render.
    class ResponseRendererEdgeTest < ActionDispatch::IntegrationTest
      setup do
        @group = create_permission_set_group
        @user = create_user
      end

      # A new membership for nobody is a 422 keyed by user_id
      # (BaseController#requested_user); removing the membership of someone
      # user_list_resolver leaves out is still a 404.
      test 'DELETE destroy returns a 404 envelope when the member is outside user_list_resolver' do
        membership = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @user)
        config = PermissionForge.configuration
        config.user_list_resolver = -> { config.user_model.where.not(id: @user.id) }

        delete "/permission_forge/api/permission_set_groups/#{@group.uuid}/users/#{membership.uuid}"

        assert_response :not_found
        json = JSON.parse(response.body)
        assert_equal 404, json.dig('error', 'status')
        assert_equal I18n.t('permission_forge.api.errors.not_found'), json.dig('error', 'messages')
      end

      test 'POST create returns a 422 envelope when the record fails validation' do
        PermissionForge::PermissionSetGroupUser.create!(
          uuid: SecureRandom.uuid,
          permission_set_group: @group,
          user: @user
        )

        post "/permission_forge/api/permission_set_groups/#{@group.uuid}/users", params: { user_id: @user.id }

        assert_response :unprocessable_entity
        json = JSON.parse(response.body)
        assert_equal 422, json.dig('error', 'status')
        assert_includes json.dig('error', 'messages').keys, 'user_id'
      end
    end

    # Unit coverage for the AMS render branches. active_model_serializers is not
    # a dependency of this gem, so ams_serializer? is overridden to force the
    # branch; the assertions pin the exact arguments handed to Rails' renderer.
    class ResponseRendererAmsBranchTest < ActiveSupport::TestCase
      FakeAmsSerializer = Class.new

      class StubController
        include PermissionForge::Api::ResponseRenderer

        attr_reader :render_args

        def render(**args)
          @render_args = args
        end

        private

        def ams_serializer?(_serializer_class)
          true
        end

        def default_paginate_scope(scope)
          scope
        end

        def pagination_meta(_records)
          { pagination: { page: 1, per_page: 15, total_count: 2 } }
        end
      end

      setup do
        @controller = StubController.new
        @record = Object.new
      end

      test 'render_record passes AMS serializer arguments to render' do
        @controller.send(:render_record, @record, FakeAmsSerializer)

        assert_equal(
          { json: @record, serializer: FakeAmsSerializer, root: :data, status: :ok },
          @controller.render_args
        )
      end

      test 'render_created passes AMS serializer arguments with created status' do
        @controller.send(:render_created, @record, FakeAmsSerializer)

        assert_equal(
          { json: @record, serializer: FakeAmsSerializer, root: :data, status: :created },
          @controller.render_args
        )
      end

      test 'render_collection passes each_serializer and meta for AMS serializers' do
        records = [@record]

        @controller.send(:render_collection, records, FakeAmsSerializer)

        args = @controller.render_args
        assert_equal records, args[:json]
        assert_equal FakeAmsSerializer, args[:each_serializer]
        assert_equal :data, args[:root]
        assert_equal({ pagination: { page: 1, per_page: 15, total_count: 2 } }, args[:meta])
        assert_equal :ok, args[:status]
      end

      test 'render_not_found honors a custom message' do
        @controller.send(:render_not_found, 'Missing thing')

        assert_equal(
          { json: { error: { status: 404, messages: 'Missing thing' } }, status: :not_found },
          @controller.render_args
        )
      end
    end
  end
end
