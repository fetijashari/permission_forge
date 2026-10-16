# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/pseudo_locale'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Api
    # One schema per envelope (Api::Schema): every API route, in its success
    # and in every error class that applies to it, answers a body the schema
    # declares — or no body where BODILESS says so — and every message is a
    # translation of the request's language (the pseudo-locale `xx` wraps
    # every string of the gem's en file, test/support/pseudo_locale.rb).
    # Every serializer's keys are its schema entry, and every route has an
    # Endpoint. A new route, error path or serializer key is covered without
    # editing this file; the fixtures at the end prove each check bites.
    class EnvelopeSchemaTest < ActionDispatch::IntegrationTest
      include PermissionForge::Tenancy::TenancyTestHelper

      ROOT = '/permission_forge'
      UNKNOWN = '00000000-0000-4000-8000-000000000000'
      HEADERS = { 'Accept-Language' => PseudoLocale::LOCALE.to_s }.freeze
      MUTATING = %w[post patch put delete].freeze
      # The scenarios whose answer has no body (Schema::BODILESS); any other
      # bodiless answer is a failure.
      BODILESS_SCENARIOS = ['401 api_auth not set', '404 API disabled', '204 success'].freeze

      # The body that makes a mutating route a 422, per "controller#action"
      # (controller under permission_forge/api/). A route not here and not in
      # NO_UNPROCESSABLE fails the coverage test.
      UNPROCESSABLE = {
        'permission_sets#create' => { permission_set: 'x' }, 'permission_sets#update' => { permission_set: 'x' },
        'resources#create' => { resource: 'x' }, 'resources#update' => { resource: 'x' },
        'resources#generate_fields' => { grant_all: 'yes' },
        'resource_fields#create' => { resource_field: 'x' }, 'resource_fields#update' => { resource_field: 'x' },
        'resource_actions#create' => { resource_action: 'x' }, 'resource_actions#update' => { resource_action: 'x' },
        'permission_set_rules#create' => { permission_set_rule: 'x' }, 'permission_set_rules#update' => { permission_set_rule: 'x' },
        'permission_set_users#create' => { user_id: '' }, 'permission_set_users#bulk' => { bulk_action: 'nope', user_ids: [1] },
        'permission_set_groups#create' => { permission_set_group: 'x' }, 'permission_set_groups#update' => { permission_set_group: 'x' },
        'permission_set_group_users#create' => { user_id: '' },
        'audit_events#index' => { from: '2026-02-30' }
      }.freeze
      # Mutating routes that read nothing a client can get wrong.
      NO_UNPROCESSABLE = {
        'permission_sets#clone' => 'an unreadable name is the default copy name',
        'permission_set_groups#clone' => 'an unreadable name is the default copy name',
        'unmatched_routes#show' => 'answers its 404 to everything'
      }.freeze
      # Mutating routes the lock on their record does not refuse (a 403
      # elsewhere), with why.
      LOCK_ALLOWS = {
        'permission_sets#create' => 'a new set is not locked',
        'permission_set_groups#create' => 'a new group is not locked',
        'permission_sets#clone' => 'the copy is editable',
        'permission_set_groups#clone' => 'the copy is editable',
        'permission_set_users#destroy' => 'revoking narrows a granting set',
        'unmatched_routes#show' => 'answers its 404 to everything'
      }.freeze
      # A valid request, per route; {} when it needs nothing.
      VALID = {
        'permission_sets#create' => { permission_set: { name: 'Created' } },
        'permission_sets#update' => { permission_set: { description: 'Changed' } },
        'resources#create' => { resource: { name: 'Supplier', read_access: true } },
        'resources#update' => { resource: { description: 'Changed' } },
        'resources#generate_fields' => { grant_all: true },
        'resource_fields#create' => { resource_field: { name: 'domain', label: 'Domain' } },
        'resource_fields#update' => { resource_field: { label: 'E-mail' } },
        'resource_actions#create' => { resource_action: { name: 'archive' } },
        'resource_actions#update' => { resource_action: { label: 'Export' } },
        'permission_set_rules#create' => { permission_set_rule: { name: 'Own', field_name: 'name', operator: 'equal', field_value: 'x' } },
        'permission_set_rules#update' => { permission_set_rule: { name: 'Renamed' } },
        'permission_set_users#create' => { user_id: :other }, 'permission_set_users#bulk' => { bulk_action: 'assign', user_ids: [:other] },
        'permission_set_groups#create' => { permission_set_group: { name: 'Created group' } },
        'permission_set_groups#update' => { permission_set_group: { description: 'Changed' } },
        'permission_set_group_users#create' => { user_id: :other }
      }.freeze

      # [verb, path spec, "controller#action"] for every API route, one entry per verb.
      def self.routes
        PermissionForge::Engine.routes.routes.flat_map do |route|
          controller = route.requirements[:controller].to_s
          next [] unless controller.start_with?('permission_forge/api/')

          key = "#{controller.delete_prefix('permission_forge/api/')}##{route.requirements[:action]}"
          route.verb.to_s.split('|').map { |verb| [verb.downcase, route.path.spec.to_s.sub('(.:format)', ''), key] }
        end.uniq
      end

      setup do
        PseudoLocale.install!
        base_configuration!
        @set = create_permission_set(name: 'Sales')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource)
        @action = create_resource_action(resource: @resource)
        @group = create_permission_set_group(name: 'Team')
        @user = create_user(name: 'Ana')
        @other = create_user(name: 'Bo')
        @assignment = create_permission_set_user(user: @user, permission_set: @set)
        @member = PermissionForge::PermissionSetGroupUser.create!(permission_set_group: @group, user: @user)
        @set.update!(permission_set_group: @group)
        @event = PermissionForge::AuditEvent.order(:id).last
      end

      teardown do
        PseudoLocale.remove!
      end

      routes.each do |verb, spec, key|
        test "#{verb.upcase} #{spec} (#{key}) answers the schema in its success and in every error class" do
          failures = scenarios(verb, spec, key).flat_map do |label, expected_status, run|
            reset_scenario!
            run.call
            check_answer("#{verb.upcase} #{spec} #{label}", expected_status, key, bodiless: BODILESS_SCENARIOS.include?(label))
          ensure
            reset_scenario!
          end

          assert_empty failures, failures.join("\n")
        end
      end

      test 'every API route has an Endpoint, and every Endpoint a route' do
        keys = self.class.routes.map(&:last).uniq
        assert_empty keys - Schema::ENDPOINTS.keys, 'routes without an Api::Schema::ENDPOINTS entry'
        assert_empty Schema::ENDPOINTS.keys - keys, 'ENDPOINTS entries no route reaches'
      end

      test 'every mutating route says how it answers 422, or why it never does' do
        mutating = self.class.routes.select { |verb, _, key| MUTATING.include?(verb) && !key.end_with?('#destroy') }.map(&:last).uniq
        assert_empty mutating - UNPROCESSABLE.keys - NO_UNPROCESSABLE.keys
      end

      test "every serializer's keys are its Api::Schema payload, and every payload has its serializer" do
        serializers = Serializers.constants.map { |name| Serializers.const_get(name) }
                                 .select { |klass| klass.is_a?(Class) && klass < Serializers::BaseSerializer }
        names = serializers.map { |klass| payload_name(klass) }
        assert_equal Schema::PAYLOADS.keys.sort, names.sort, 'a serializer without a payload, or a payload without a serializer'
        serializers.each { |klass| assert_empty serializer_mismatch(klass), klass.name }
        assert_equal Schema::PAYLOADS.keys.sort, PermissionForge::Api::BaseController.new.send(:default_serializers).keys.sort
      end

      test 'every key that holds the numeric id of another PermissionForge record is a foreign identifier' do
        host_or_text = %w[id user_id actor_id record_id subject_user_id request_id correlation_id]
        Schema::PAYLOADS.each do |name, fields|
          id_keys = fields.keys.map(&:to_s).select { |key| key.end_with?('_id') || key == 'id' } - host_or_text
          assert_equal id_keys.sort, Schema.foreign_identifiers(name).map(&:to_s).sort, name.to_s
        end
        assert_equal %i[permission_set_group_id], Schema.foreign_identifiers(:permission_set)
        assert_equal %i[permission_set_id resource_id], Schema.foreign_identifiers(:permission_set_rule)
      end

      test 'a foreign identifier still answers the numeric id (unchanged until a later version)' do
        get "#{ROOT}/api/permission_sets/#{@set.uuid}"
        assert_equal @group.id, response.parsed_body.dig('data', 'permission_set_group_id')
      end

      # --- the checks bite ------------------------------------------------------

      test 'a key added to a serializer without the schema, or dropped from it, is reported' do
        keys = Schema.payload_keys(:resource)
        added = Class.new(Serializers::BaseSerializer) { attributes(*keys, :secret) }
        dropped = Class.new(Serializers::BaseSerializer) { attributes(*(keys - [:view_all])) }
        assert_equal ['resource answers secret, which Api::Schema does not declare'], serializer_mismatch(added, :resource)
        assert_equal ['resource lacks view_all, which Api::Schema declares'], serializer_mismatch(dropped, :resource)
      end

      test 'a body off the schema is reported: extra or missing key, wrong type, null where none is allowed' do
        get "#{ROOT}/api/permission_sets/#{@set.uuid}"
        body = response.parsed_body
        endpoint = Schema::ENDPOINTS.fetch('permission_sets#show')
        assert_empty Schema.success_problems(endpoint, body)
        bad = body.deep_dup
        bad['data']['secret'] = 1
        bad['data'].delete('is_muting')
        bad['data']['permission_set_group_id'] = @group.uuid
        bad['data']['name'] = nil
        bad['data']['created_at'] = 'yesterday'
        assert_equal ['$.data.secret: not declared in Api::Schema', '$.data.is_muting: missing',
                      '$.data.name: expected string, got nil', '$.data.permission_set_group_id: expected foreign_identifier?, ' \
                                                              "got #{@group.uuid.inspect}",
                      '$.data.created_at: expected time, got "yesterday"'], Schema.success_problems(endpoint, bad)
        assert_equal ['$.meta: missing'], Schema.success_problems(Schema::ENDPOINTS.fetch('permission_sets#index'), { 'data' => [] })
      end

      test 'an error body off the schema is reported; no body only where BODILESS says' do
        assert_empty Schema.error_problems(404, Schema.error_body(404, 'x'))
        assert_equal ['$.error.messages: expected field_messages, got "x"'], Schema.error_problems(422, Schema.error_body(422, 'x'))
        assert_equal ['$.error.messages: expected string, got {"a" => ["b"]}'],
                     Schema.error_problems(403, Schema.error_body(403, { 'a' => ['b'] }))
        assert_equal ['$.error.status: expected 404, got 403'], Schema.error_problems(404, Schema.error_body(403, 'x'))
        assert_equal ['400: no body, and BODILESS does not declare one'], Schema.error_problems(400, nil)
        assert_equal ['500: not an error status of the schema (400, 401, 403, 404, 422)'], Schema.error_problems(500, {})
        assert_empty Schema.error_problems(401, nil)
      end

      test 'a message that is no translation of the request language is reported' do
        assert_equal ['$.error.messages: "Not authenticated" is not a translation of xx'],
                     message_problems(Schema.error_body(401, 'Not authenticated'))
        assert_empty message_problems(Schema.error_body(401, I18n.t('permission_forge.api.errors.unauthorized', locale: :xx)))
      end

      private

      def base_configuration!
        config = PermissionForge.configuration
        config.available_locales = [:en, PseudoLocale::LOCALE]
        config.api_action_authorization = ->(*) { true }
        config.api_assignment_authorization = ->(*) { true }
      end

      def reset_scenario!
        [@set, @group].each { |record| record.update!(is_editable: true) if record.class.exists?(record.id) && !record.reload.is_editable }
        ConfigurationSnapshot.restore!
        base_configuration!
        ActsAsTenant.test_tenant = DEFAULT_TEST_ACCOUNT
        ActsAsTenant.current_tenant = nil
      end

      # [label, expected status, request] for every class that applies to the route.
      def scenarios(verb, spec, key)
        path = build_path(spec)
        mutating = MUTATING.include?(verb) && key != 'unmatched_routes#show'
        request = ->(params = valid_params(key), target = path) { send(verb, target, params: params, headers: HEADERS, as: :json) }
        endpoint = Schema::ENDPOINTS.fetch(key)
        list = []
        list << ['401 api_auth refuses', 401, -> { PermissionForge.configuration.api_auth = ->(_) { false }; request.call }]
        list << ['401 api_auth not set', 401, -> { PermissionForge.configuration.api_auth = nil; request.call }]
        list << ['404 API disabled', 404, -> { PermissionForge.configuration.api_enabled = false; request.call }]
        list << ['403 no tenant', 403, -> { no_tenant!; request.call }]
        list << ['404 unknown record', 404, -> { request.call(valid_params(key), build_path(spec, unknown: true)) }] if spec.include?(':')
        list << ['400 unreadable body', 400, -> { send(verb, path, params: '{"x": ', headers: HEADERS.merge('CONTENT_TYPE' => 'application/json')) }] if verb != 'get'
        list << ['422 unreadable input', 422, -> { request.call(resolve(UNPROCESSABLE[key])) }] if UNPROCESSABLE.key?(key)
        list << ['403 refused by the authorization lambdas', 403, -> { refuse_everything!; request.call }] if mutating || refusable?(key)
        list << ['403 locked', 403, -> { lock!; request.call }] if mutating && !LOCK_ALLOWS.key?(key)
        list << ["#{endpoint.status} success", endpoint.status, -> { request.call }]
        list
      end

      def refusable?(key) = %w[dashboard#show audit_events#index audit_events#show].include?(key)

      def refuse_everything!
        config = PermissionForge.configuration
        config.api_action_authorization = ->(*) { false }
        config.api_assignment_authorization = ->(*) { false }
        config.api_stats_require_admin = true
        config.api_stats_authorization = ->(_) { false }
        config.audit_log_authorization = ->(_) { false }
      end

      def lock!
        [@set, @group].each { |record| record.update!(is_editable: false) }
      end

      def check_answer(label, expected_status, key, bodiless:)
        failures = []
        failures << "#{label}: status #{response.status}, expected #{expected_status} (#{response.body.to_s[0, 160]})" if response.status != expected_status
        body = response.body.presence && JSON.parse(response.body)
        failures << "#{label}: no body" if body.nil? && !bodiless
        failures << "#{label}: a body where none is declared" if body && bodiless
        problems = if response.status == expected_status && expected_status < 400
                     Schema.success_problems(Schema::ENDPOINTS.fetch(key), body)
                   else
                     Schema.error_problems(response.status, body)
                   end
        problems += message_problems(body) if body
        problems += empty_collection(body, key) if body && expected_status < 300
        failures + problems.map { |problem| "#{label}: #{problem}" }
      rescue JSON::ParserError
        ["#{label}: not JSON: #{response.body.to_s[0, 160]}"]
      end

      # A collection with nothing in it would check no payload.
      def empty_collection(body, key)
        data = body['data']
        data.is_a?(Array) && data.empty? ? ["#{key}: an empty list checks no payload; give the fixtures a row"] : []
      end

      # Every message of an error body must be a translation of xx with no
      # untranslated prose left (interpolated host data aside).
      def message_problems(body)
        messages = body.is_a?(Hash) && body.dig('error', 'messages')
        return [] unless messages

        Array(messages.is_a?(Hash) ? messages.values.flatten : messages).filter_map do |text|
          leaks = PseudoLocale.leaks(text, vocabulary)
          next if text.include?(PseudoLocale::OPEN) && leaks.empty?

          "$.error.messages: #{text.inspect} is not a translation of xx#{" (#{leaks.join(', ')})" if leaks.any?}"
        end
      end

      def vocabulary
        @vocabulary ||= PseudoLocale.vocabulary(%w[Customer Supplier name email domain archive Sales Team Ana Bo x])
      end

      def payload_name(klass)
        klass.name.demodulize.delete_suffix('Serializer').underscore.to_sym
      end

      def serializer_mismatch(klass, name = payload_name(klass))
        declared = Schema.payload_keys(name)
        answered = klass.attribute_names
        (answered - declared).map { |key| "#{name} answers #{key}, which Api::Schema does not declare" } +
          (declared - answered).map { |key| "#{name} lacks #{key}, which Api::Schema declares" }
      end

      def valid_params(key) = resolve(VALID.fetch(key, {}))

      # :other in a parameter is the id of the person no set holds yet.
      def resolve(params)
        params.to_h.transform_values do |value|
          case value
          when :other then @other.id
          when Array then value.map { |item| item == :other ? @other.id : item }
          else value
          end
        end
      end

      def build_path(spec, unknown: false)
        identifiers = {
          ':permission_set_identifier' => @set.uuid, ':resource_identifier' => @resource.uuid,
          ':permission_set_group_identifier' => @group.uuid, ':identifier' => nil, '(/*path)' => '/no/such/endpoint'
        }
        identifiers = identifiers.to_h { |name, value| [name, name.start_with?(':') ? UNKNOWN : value] } if unknown
        identifiers.reduce(ROOT + spec) { |path, (name, value)| path.gsub(name, (value || identifier_for(path)).to_s) }
      end

      # The record an :identifier names, by the path's last collection.
      def identifier_for(path)
        records = { 'permission_sets' => @set, 'resources' => @resource, 'fields' => @field, 'actions' => @action,
                    'rules' => @rule, 'audit_events' => @event, 'permission_set_groups' => @group }
        collection = path[%r{/(\w+)/:identifier}, 1]
        return (path.include?('permission_set_groups') ? @member : @assignment).uuid if collection == 'users'

        records.fetch(collection).uuid
      end
    end
  end
end
