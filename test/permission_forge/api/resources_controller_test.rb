# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class ResourcesControllerTest < ActionDispatch::IntegrationTest
      setup do
        @ps = create_permission_set
      end

      test 'GET index returns resources for a permission set' do
        create_resource(permission_set: @ps, name: 'Customer')
        create_resource(permission_set: @ps, name: 'Supplier')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
      end

      test 'GET show returns a single resource' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        get "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'Customer', json.dig('data', 'name')
        assert json.dig('data', 'read_access')
      end

      test 'POST create creates a resource' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Article', read_access: true, create_access: false, edit_access: true, delete_access: false }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'Article', json.dig('data', 'name')
        assert json.dig('data', 'read_access')
        assert json.dig('data', 'edit_access')
        refute json.dig('data', 'create_access')
      end

      test 'PATCH update modifies a resource' do
        resource = create_resource(permission_set: @ps, name: 'Customer', edit_access: false)

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}", params: {
          resource: { edit_access: true }
        }

        assert_response :ok
        assert resource.reload.edit_access
      end

      test 'DELETE destroy removes a resource' do
        resource = create_resource(permission_set: @ps)

        delete "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}"

        assert_response :no_content
        assert_nil PermissionForge::Resource.find_by(id: resource.id)
      end

      test 'POST create with view_all and modify_all' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Project', read_access: true, view_all: true, modify_all: true }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert json.dig('data', 'view_all')
        assert json.dig('data', 'modify_all')
      end

      test 'PATCH update view_all and modify_all' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        patch "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}", params: {
          resource: { view_all: true, modify_all: true }
        }

        assert_response :ok
        resource.reload
        assert resource.view_all
        assert resource.modify_all
      end

      test 'POST create rejects edit_access without read_access' do
        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources", params: {
          resource: { name: 'Bad', read_access: false, edit_access: true }
        }

        assert_response :unprocessable_entity
      end

      # A Resource named after a constant that is no model with a table
      # (`Kernel`, `String`, a model whose table is not there) has no columns
      # to generate rows from: a 422 keyed by name, never a 500 and never the
      # generic message.
      test 'POST generate_fields on a Resource naming no model this app can load is a 422 on name' do
        %w[Kernel String PermissionForge].each do |name|
          resource = create_resource(permission_set: @ps, name: name)

          post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields",
               params: { grant_all: 'true' }

          assert_response :unprocessable_entity, name
          assert_equal({ 'name' => [I18n.t('permission_forge.api.errors.resource_names_no_model')] },
                       JSON.parse(response.body).dig('error', 'messages'), name)
          assert_equal 0, resource.resource_fields.count, name
        end
      end

      test 'POST generate_fields auto-generates fields' do
        resource = create_resource(permission_set: @ps, name: 'Customer')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields",
             params: { grant_all: 'true' }

        assert_response :created
        json = JSON.parse(response.body)
        assert json['data'].is_a?(Array)
        assert json['data'].size.positive?
      end

      # grant_all asks for full access: no personal-data mask, whatever
      # gdpr_defaults says (the recommended strategy is kept for later).
      test 'POST generate_fields with grant_all applies no masks under gdpr_defaults' do
        PermissionForge.configuration.gdpr_defaults = true
        resource = create_resource(permission_set: @ps, name: 'Customer')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields",
             params: { grant_all: 'true' }

        assert_response :created
        fields = JSON.parse(response.body)['data'].index_by { |field| field['name'] }
        name = fields.fetch('name')
        assert_equal [true, true, false, 'first1_last4'], name.values_at('read_access', 'edit_access', 'mask_access', 'mask_strategy')
        assert_equal([], fields.values.select { |field| field['mask_access'] }.map { |field| field['name'] })
      end

      test 'POST generate_fields without grant_all keeps the privacy defaults' do
        PermissionForge.configuration.gdpr_defaults = true
        resource = create_resource(permission_set: @ps, name: 'Customer')

        post "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{resource.uuid}/generate_fields"

        assert_response :created
        fields = JSON.parse(response.body)['data'].index_by { |field| field['name'] }
        assert_equal [true, false, true, 'email'], fields.fetch('email').values_at('read_access', 'edit_access', 'mask_access', 'mask_strategy')
        assert_equal [false, false, false], fields.fetch('domain').values_at('read_access', 'edit_access', 'mask_access')
      end

      # A JSON true (or 1) used to read as false: 201 with fields without edit.
      test 'POST generate_fields reads grant_all as a JSON boolean, 1 or their strings' do
        { true => true, 'true' => true, 1 => true, '1' => true,
          false => false, 'false' => false, 0 => false, '0' => false, nil => false }.each do |value, editable|
          fields = generate_fields_with(grant_all: value).index_by { |field| field['name'] }
          assert_response :created, value.inspect
          assert_equal editable, fields.fetch('name')['edit_access'], value.inspect
        end
      end

      test 'POST generate_fields refuses a grant_all it cannot read with a 422 keyed by grant_all' do
        resource = create_resource(permission_set: @ps, name: 'Customer')
        expected = { 'grant_all' => [I18n.t('permission_forge.api.errors.boolean_invalid')] }

        ['yes', 'TRUE', '', 2, 1.5, [true], { 'a' => 1 }].each do |value|
          assert_no_difference -> { resource.resource_fields.count } do
            post "#{resources_path}/#{resource.uuid}/generate_fields", params: { grant_all: value }, as: :json
          end
          assert_response :unprocessable_entity, value.inspect
          assert_equal expected, JSON.parse(response.body).dig('error', 'messages'), value.inspect
        end
      end

      private

      def resources_path = "/permission_forge/api/permission_sets/#{@ps.uuid}/resources"

      # Generates the fields of a fresh Customer resource with `params` as JSON.
      def generate_fields_with(params)
        PermissionForge::Resource.where(permission_set: @ps).find_each(&:destroy!)
        resource = create_resource(permission_set: @ps, name: 'Customer')
        post "#{resources_path}/#{resource.uuid}/generate_fields", params: params, as: :json
        JSON.parse(response.body)['data']
      end
    end
  end
end
