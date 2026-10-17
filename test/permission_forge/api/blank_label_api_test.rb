# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Api
    # Field test round 8 (D#25): PATCH a field row's `label: null` answered
    # 422 {"label": ["can't be blank"]} while `label: ""` answered 200 and
    # stored the empty label; an action row stored both as sent. A blank
    # label (null, "", white space) is "no label" for every row with a label
    # (Concerns::NormalizesLabel): 200 / 201, stored as the row's name — as
    # the admin stores a blanked label.
    class BlankLabelApiTest < ActionDispatch::IntegrationTest
      BLANKS = [nil, '', '   '].freeze

      setup do
        @ps = create_permission_set
        @resource = create_resource(permission_set: @ps, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', label: 'E-mail address', read_access: true)
        @action = create_resource_action(resource: @resource, name: 'export', label: 'Export CSV')
      end

      def base = "/permission_forge/api/permission_sets/#{@ps.uuid}/resources/#{@resource.uuid}"

      test 'a blank label is stored as the name on PATCH, for a field row and an action row alike' do
        BLANKS.each do |blank|
          @field.update!(label: 'E-mail address')
          @action.update!(label: 'Export CSV')

          patch "#{base}/fields/#{@field.uuid}", params: { resource_field: { label: blank } }, as: :json
          assert_response :ok, "field #{blank.inspect}: #{response.body}"
          assert_equal 'email', response.parsed_body.dig('data', 'label')

          patch "#{base}/actions/#{@action.uuid}", params: { resource_action: { label: blank } }, as: :json
          assert_response :ok, "action #{blank.inspect}: #{response.body}"
          assert_equal 'export', response.parsed_body.dig('data', 'label')

          assert_equal %w[email export], [@field.reload.label, @action.reload.label], blank.inspect
        end
      end

      test 'a blank label is stored as the name on POST, for a field row and an action row alike' do
        BLANKS.each_with_index do |blank, index|
          post "#{base}/fields", params: { resource_field: { name: "col_#{index}", label: blank } }, as: :json
          assert_response :created, "field #{blank.inspect}: #{response.body}"
          assert_equal "col_#{index}", response.parsed_body.dig('data', 'label')

          post "#{base}/actions", params: { resource_action: { name: "act_#{index}", label: blank } }, as: :json
          assert_response :created, "action #{blank.inspect}: #{response.body}"
          assert_equal "act_#{index}", response.parsed_body.dig('data', 'label')
        end
      end
    end
  end
end
