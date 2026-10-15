# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    class PermissionSetsControllerTest < ActionDispatch::IntegrationTest
      # ---------- INDEX ----------

      test 'GET index returns all permission sets' do
        create_permission_set(name: 'Alpha')
        create_permission_set(name: 'Beta')

        get '/permission_forge/api/permission_sets'

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 2, json['data'].size
        assert(json['data'].all? { |d| d.key?('uuid') })
      end

      # ---------- SHOW ----------

      test 'GET show returns permission set by uuid' do
        ps = create_permission_set(name: 'Sales Team')

        get "/permission_forge/api/permission_sets/#{ps.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'Sales Team', json.dig('data', 'name')
        assert_equal ps.uuid, json.dig('data', 'uuid')
      end

      # ---------- CREATE ----------

      test 'POST create creates a new permission set' do
        post '/permission_forge/api/permission_sets', params: {
          permission_set: { name: 'New Set', description: 'Test', is_active: true }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'New Set', json.dig('data', 'name')
        assert PermissionForge::PermissionSet.find_by(name: 'New Set')
      end

      # docs/admin-api.md "What answers 422": with JSON parameter wrapping on
      # (load_defaults 7.0+, as in the dummy app) Rails copies a flat JSON
      # body's model attributes under the section; an empty or missing
      # section is a 422.
      test 'POST create wraps a flat JSON body into the section' do
        post '/permission_forge/api/permission_sets', params: { name: 'Flat payload' }.to_json,
                                                      headers: { 'CONTENT_TYPE' => 'application/json' }

        assert_response :created
        assert PermissionForge::PermissionSet.find_by(name: 'Flat payload')
      end

      test 'POST create answers 422 for an empty or missing section' do
        post '/permission_forge/api/permission_sets', params: { not_an_attribute: 'x' }.to_json,
                                                      headers: { 'CONTENT_TYPE' => 'application/json' }
        assert_response :unprocessable_entity
        assert_equal({ 'permission_set' => [I18n.t('permission_forge.api.errors.section_missing')] },
                     JSON.parse(response.body).dig('error', 'messages'))

        post '/permission_forge/api/permission_sets', params: { name: 'Form-encoded' }
        assert_response :unprocessable_entity
        assert_nil PermissionForge::PermissionSet.find_by(name: 'Form-encoded')
      end

      # One 422 shape: input errors are field-keyed like validation errors.
      test 'a section that is not an object is a field-keyed 422, like a validation error' do
        post '/permission_forge/api/permission_sets', params: { permission_set: 'x' }.to_json,
                                                      headers: { 'CONTENT_TYPE' => 'application/json' }
        assert_response :unprocessable_entity
        assert_equal({ 'status' => 422, 'messages' => { 'permission_set' => [I18n.t('permission_forge.api.errors.section_missing')] } },
                     JSON.parse(response.body)['error'])

        post '/permission_forge/api/permission_sets', params: { permission_set: { name: '' } }, as: :json
        assert_response :unprocessable_entity
        assert_kind_of Array, JSON.parse(response.body).dig('error', 'messages', 'name')
      end

      # ---------- UPDATE ----------

      test 'PATCH update modifies permission set' do
        ps = create_permission_set(name: 'Old Name')

        patch "/permission_forge/api/permission_sets/#{ps.uuid}", params: {
          permission_set: { name: 'New Name' }
        }

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal 'New Name', json.dig('data', 'name')
        assert_equal 'New Name', ps.reload.name
      end

      # ---------- DESTROY ----------

      test 'DELETE destroy removes permission set' do
        ps = create_permission_set

        delete "/permission_forge/api/permission_sets/#{ps.uuid}"

        assert_response :no_content
        assert_nil PermissionForge::PermissionSet.find_by(id: ps.id)
      end

      # ---------- MUTING ----------

      test 'POST create creates a muting permission set' do
        post '/permission_forge/api/permission_sets', params: {
          permission_set: { name: 'Muting Set', is_muting: true }
        }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal true, json.dig('data', 'is_muting')
        assert PermissionForge::PermissionSet.find_by(name: 'Muting Set').is_muting
      end

      test 'GET show includes is_muting in response' do
        ps = create_permission_set(name: 'Muting Set', is_muting: true)

        get "/permission_forge/api/permission_sets/#{ps.uuid}"

        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal true, json.dig('data', 'is_muting')
      end

      test 'PATCH update can toggle is_muting' do
        ps = create_permission_set(name: 'Toggle Set', is_muting: false)

        patch "/permission_forge/api/permission_sets/#{ps.uuid}", params: {
          permission_set: { is_muting: true }
        }

        assert_response :ok
        assert ps.reload.is_muting
      end

      test 'POST clone preserves is_muting flag' do
        ps = create_permission_set(name: 'Muting Original', is_muting: true)
        create_resource(permission_set: ps, name: 'Customer')

        post "/permission_forge/api/permission_sets/#{ps.uuid}/clone", params: { name: 'Cloned Muting' }

        assert_response :created
        cloned = PermissionForge::PermissionSet.find_by(name: 'Cloned Muting')
        assert cloned.is_muting, 'cloned set should preserve is_muting'
      end

      test 'GET index returns is_muting for each permission set' do
        create_permission_set(name: 'Granting')
        create_permission_set(name: 'Muting', is_muting: true)

        get '/permission_forge/api/permission_sets'

        assert_response :ok
        json = JSON.parse(response.body)
        muting_flags = json['data'].map { |d| d['is_muting'] }
        assert_includes muting_flags, true
        assert_includes muting_flags, false
      end

      # ---------- CLONE ----------

      test 'POST clone deep-clones permission set' do
        ps = create_permission_set(name: 'Original')
        resource = create_resource(permission_set: ps, name: 'Customer')
        create_resource_field(resource: resource, name: 'email')

        post "/permission_forge/api/permission_sets/#{ps.uuid}/clone", params: { name: 'Cloned Set' }

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal 'Cloned Set', json.dig('data', 'name')

        cloned = PermissionForge::PermissionSet.find_by(name: 'Cloned Set')
        assert cloned
        assert_equal 1, cloned.resources.count
        assert_equal 1, cloned.resources.first.resource_fields.count
      end

      # The admin's Duplicate and the cloners name a copy "<name> (copy)"
      # (permission_sets.copy_name); the API said "(Copy)" in English.
      test 'POST clone without a name names the copy as the admin does, numbered when taken, in the request locale' do
        ps = create_permission_set(name: 'Original')
        names = Array.new(2) do
          post "/permission_forge/api/permission_sets/#{ps.uuid}/clone"
          assert_response :created
          response.parsed_body.dig('data', 'name')
        end
        assert_equal ['Original (copy)', 'Original (copy) 2'], names

        post "/permission_forge/api/permission_sets/#{ps.uuid}/clone", headers: { 'HTTP_ACCEPT_LANGUAGE' => 'sq' }
        assert_equal I18n.t('permission_forge.permission_sets.copy_name', name: 'Original', locale: :sq),
                     response.parsed_body.dig('data', 'name')

        group = create_permission_set_group(name: 'Team')
        post "/permission_forge/api/permission_set_groups/#{group.uuid}/clone", headers: { 'HTTP_ACCEPT_LANGUAGE' => 'mk' }
        assert_equal I18n.t('permission_forge.permission_sets.copy_name', name: 'Team', locale: :mk),
                     response.parsed_body.dig('data', 'name')
      ensure
        I18n.locale = I18n.default_locale
      end
    end
  end
end
