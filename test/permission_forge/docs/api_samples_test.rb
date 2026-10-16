# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/doc_blocks'
require 'permission_forge/docs/api_samples'

module PermissionForge
  module Docs
    # The ```json sample=<name> blocks of docs/admin-api.md are rendered from
    # Api::Schema and the serializers (`bundle exec rake docs:api`): the
    # committed document must be what the generator renders, every sample
    # must match the schema, and every error sample must be the body the
    # API answers for the request it stands for.
    class ApiSamplesTest < ActionDispatch::IntegrationTest
      PATH = File.expand_path('../../../docs/admin-api.md', __dir__)
      API = '/permission_forge/api'
      JSON_HEADERS = { 'CONTENT_TYPE' => 'application/json' }.freeze

      def document = @document ||= File.read(PATH)
      def samples(text = document) = ApiSamples.new(document: text, blocks: DocBlocks.parse(text, file: 'docs/admin-api.md'))

      test 'the json samples of docs/admin-api.md are what the schema and the serializers render' do
        rendered = samples.render
        assert_equal rendered, document, 'docs/admin-api.md is stale: run `bundle exec rake docs:api` and commit the result'
        assert_not samples.stale?
      end

      test 'regenerating is a no-op' do
        once = samples.render
        assert_equal once, samples(once).render
      end

      test 'every sample= block names a sample, and every sample is in the document' do
        named = DocBlocks.parse(document, file: 'docs/admin-api.md').filter_map(&:sample)
        assert_equal ApiSamples::SAMPLES.keys.sort, named.uniq.sort
      end

      test 'every sample matches Api::Schema' do
        ApiSamples::SAMPLES.each_key do |name|
          assert_empty samples.problems(name), name
        end
      end

      test 'a success sample carries every key its serializer answers' do
        data = samples.value('permission_set').fetch('data')
        assert_equal Api::Serializers::PermissionSetSerializer.attribute_names.map(&:to_s), data.keys
        assert_kind_of Integer, data.fetch('permission_set_group_id')
      end

      # Each error sample, and each line of a sample of several, is the body
      # the API answers to the request listed here (in en).
      test 'every error sample is the answer the API gives' do
        set = create_permission_set(name: 'Sales')
        resource = create_resource(permission_set: set, name: 'Customer', read_access: true)
        requests = error_requests(set, resource)
        assert_equal ApiSamples::SAMPLES.select { |_, sample| sample.error? }.keys.sort, requests.keys.sort
        requests.each do |name, calls|
          answers = calls.map do |call|
            call.call
            response.parsed_body
          end
          expected = samples.value(name)
          assert_equal expected.is_a?(Array) ? expected : [expected], answers, name
        end
      end

      # --- the guard bites -----------------------------------------------------

      test 'a hand-edited sample makes the document stale and is regenerated' do
        edited = document.sub('"Record not found"', '"Not found"')
        assert_not_equal document, edited
        assert samples(edited).stale?
        assert_equal document, samples(edited).render
      end

      test 'a serializer key the schema does not declare stops the generator' do
        keys = Api::Serializers::PermissionSetGroupSerializer.attribute_names
        replace_singleton_method(Api::Serializers::PermissionSetGroupSerializer, :attribute_names) { keys + [:secret] }
        error = assert_raises(ArgumentError) { samples.render }
        assert_includes error.message, 'PermissionSetGroupSerializer answers secret, which Api::Schema does not declare'
      ensure
        replace_singleton_method(Api::Serializers::PermissionSetGroupSerializer, :attribute_names) { keys }
      end

      test 'a sample= naming no sample stops the generator' do
        text = "```json sample=nope\n{}\n```\n"
        error = assert_raises(ArgumentError) { samples(text).render }
        assert_includes error.message, 'docs/admin-api.md:1: sample=nope names no sample'
      end

      test 'a sample off the schema is reported' do
        sample = ApiSamples::Sample.new(style: :inline, schema: [:error, 404], build: ->(_) { Api::Schema.error_body(404, ['x']) })
        stubbed = ApiSamples::SAMPLES.merge('off' => sample)
        replace_const_samples(stubbed) { assert_equal ['$.error.messages: expected string, got ["x"]'], samples.problems('off') }
      end

      private

      # ResourceFieldGenerator raising, for the generic 422 of generate_fields.
      def failing_generator
        generator = Services::ResourceFieldGenerator
        original = generator.method(:call).unbind
        replace_singleton_method(generator, :call) { |**| raise 'boom' }
        yield
      ensure
        replace_singleton_method(generator, :call, original)
      end

      def replace_const_samples(value)
        original = ApiSamples::SAMPLES
        ApiSamples.send(:remove_const, :SAMPLES)
        ApiSamples.const_set(:SAMPLES, value)
        yield
      ensure
        ApiSamples.send(:remove_const, :SAMPLES)
        ApiSamples.const_set(:SAMPLES, original)
      end

      def error_requests(set, resource)
        resources = "#{API}/permission_sets/#{set.uuid}/resources"
        {
          'validation_error' => [-> { post "#{API}/permission_sets", params: { permission_set: { name: '' } }, as: :json }],
          'not_found' => [-> { get "#{API}/permission_sets/00000000-0000-4000-8000-000000000000" }],
          'route_not_found' => [-> { get "#{API}/unknown" }],
          'body_unreadable' => [-> { post "#{API}/permission_sets", params: '{"permission_set": {"name": "x"', headers: JSON_HEADERS }],
          'action_name_invalid' => [lambda {
            post "#{resources}/#{resource.uuid}/actions", params: { resource_action: { name: 'Export' } }, as: :json
          }],
          'input_errors' => input_error_requests(set, resource, resources)
        }
      end

      def input_error_requests(set, resource, resources)
        users = "#{API}/permission_sets/#{set.uuid}/users"
        [
          -> { post users, params: { user_id: create_user.id, expires_at: 'tuesday' }, as: :json },
          -> { post "#{API}/permission_sets", params: { permission_set: 'x' }, as: :json },
          -> { post "#{users}/bulk", params: { bulk_action: 'nope', user_ids: [1] }, as: :json },
          -> { post "#{users}/bulk", params: { bulk_action: 'assign', user_ids: [] }, as: :json },
          -> { post users, params: { user_id: 0 }, as: :json },
          -> { post "#{resources}/#{resource.uuid}/generate_fields", params: { grant_all: 'yes' }, as: :json },
          -> { failing_generator { post "#{resources}/#{resource.uuid}/generate_fields", params: { grant_all: true }, as: :json } }
        ]
      end
    end
  end
end
