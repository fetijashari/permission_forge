# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Field test round 8 (D#29, round 7 #50): under api_record_identifier =
    # :uuid every answer named the records it refers to by their numeric id
    # only — a set said `permission_set_group_id: 4` right after the PATCH
    # that sent the group's uuid, and a client that only knows uuids (the
    # identifier the URLs take) could not follow it. Each reference keeps its
    # id and is followed by the record's uuid (Serializers::BaseSerializer.reference),
    # whatever the setting; the input takes the same uuid key.
    class ReferenceUuidsApiTest < ActionDispatch::IntegrationTest
      BASE = '/permission_forge/api'

      setup do
        @config = PermissionForge.configuration
        @saved = @config.api_record_identifier
        @config.api_record_identifier = :uuid
        @user = create_user
        @group = create_permission_set_group(name: 'Sales')
        @set = create_permission_set(name: 'Sales Reps')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
      end

      teardown { @config.api_record_identifier = @saved }

      def set_path = "#{BASE}/permission_sets/#{@set.uuid}"
      def resource_path = "#{set_path}/resources/#{@resource.uuid}"
      def data = response.parsed_body.fetch('data')

      def assert_reference(body, association, record)
        assert_equal [record.id, record.uuid], [body["#{association}_id"], body["#{association}_uuid"]], association
      end

      test 'a set moved into a group by its uuid answers the group by its uuid too' do
        patch set_path, params: { permission_set: { permission_set_group_id: @group.uuid } }, as: :json

        assert_response :ok
        assert_reference(data, :permission_set_group, @group)
        patch set_path, params: { permission_set: { permission_set_group_id: nil } }, as: :json
        assert_equal [nil, nil], data.values_at('permission_set_group_id', 'permission_set_group_uuid')
      end

      test 'every answer names the set, the Resource and the group it refers to by their uuids' do
        field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        action = create_resource_action(resource: @resource, name: 'export')
        rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        assignment = create_permission_set_user(user: @user, permission_set: @set)
        membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @user)

        get resource_path
        assert_reference(data, :permission_set, @set)
        get "#{resource_path}/fields/#{field.uuid}"
        assert_reference(data, :resource, @resource)
        get "#{resource_path}/actions/#{action.uuid}"
        assert_reference(data, :resource, @resource)
        get "#{resource_path}/rules/#{rule.uuid}"
        assert_reference(data, :permission_set, @set)
        assert_reference(data, :resource, @resource)
        get "#{set_path}/users"
        assert_equal([assignment.uuid], data.map { |row| row['uuid'] })
        assert_reference(data.first, :permission_set, @set)
        get "#{BASE}/permission_set_groups/#{@group.uuid}/users"
        assert_equal([membership.uuid], data.map { |row| row['uuid'] })
        assert_reference(data.first, :permission_set_group, @group)
      end

      test 'the uuids are there under api_record_identifier = :id too' do
        @config.api_record_identifier = :id
        get "#{BASE}/permission_sets/#{@set.id}/resources/#{@resource.id}"

        assert_response :ok
        assert_reference(data, :permission_set, @set)
      end

      test 'a page looks the uuids up in one query per reference, however many rows it has' do
        other = create_permission_set(name: 'Support')
        rules = [@set, other].flat_map do |set|
          resource = set == @set ? @resource : create_resource(permission_set: other, name: 'Customer', read_access: true)
          Array.new(3) { |index| create_permission_set_rule(permission_set: set, resource: resource, name: "Rule #{index}") }
        end
        records = PermissionSetRule.where(id: rules.map(&:id)).order(:id).to_a

        tables = []
        callback = ->(*, payload) { tables << payload[:sql][/FROM\s+"?(\w+)"?/i, 1] if payload[:sql].start_with?('SELECT') }
        rows = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          Serializers::PermissionSetRuleSerializer.collection(records)
        end

        assert_equal [PermissionSet.table_name, Resource.table_name].sort, tables.sort
        assert_equal(([@set.uuid] * 3) + ([other.uuid] * 3), rows.map { |row| row[:permission_set_uuid] })
      end

      test 'permission_set_group_uuid is read as the group, under either identifier setting' do
        %i[uuid id].each do |identifier|
          @config.api_record_identifier = identifier
          @set.update!(permission_set_group: nil)
          patch "#{BASE}/permission_sets/#{@set.public_send(identifier)}",
                params: { permission_set: { permission_set_group_uuid: @group.uuid } }, as: :json

          assert_response :ok, "#{identifier}: #{response.body}"
          assert_equal @group.id, @set.reload.permission_set_group_id, identifier
          assert_reference(data, :permission_set_group, @group)
        end

        patch "#{BASE}/permission_sets/#{@set.id}", params: { permission_set: { permission_set_group_uuid: '' } }, as: :json
        assert_response :ok
        assert_nil @set.reload.permission_set_group_id
      end

      test 'an answer sent back whole moves nothing it does not name twice; two keys that disagree are a 422' do
        other = create_permission_set_group(name: 'Support')
        @set.update!(permission_set_group: @group)

        patch set_path, params: { permission_set: { permission_set_group_id: @group.id, permission_set_group_uuid: @group.uuid } }, as: :json
        assert_response :ok

        patch set_path, params: { permission_set: { permission_set_group_id: other.id, permission_set_group_uuid: @group.uuid } }, as: :json
        assert_response :unprocessable_entity
        assert_equal ['permission_set_group_uuid'], response.parsed_body.dig('error', 'messages').keys
        assert_equal @group.id, @set.reload.permission_set_group_id

        patch set_path, params: { permission_set: { permission_set_group_uuid: SecureRandom.uuid } }, as: :json
        assert_response :unprocessable_entity
        assert_equal [I18n.t('permission_forge.validations.permission_set.group_missing')],
                     response.parsed_body.dig('error', 'messages', 'permission_set_group_uuid')
      end
    end
  end
end
