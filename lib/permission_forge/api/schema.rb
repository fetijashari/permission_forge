# frozen_string_literal: true

require 'time'

module PermissionForge
  module Api
    # The one declaration of what the Admin JSON API answers: every envelope
    # (a record, a page of records, the rows one request created, an error),
    # the messages each error status carries, which answers have no body,
    # every serializer's payload (its keys and their types), the two results
    # a controller builds itself (stats, a bulk assignment), and what each
    # endpoint answers when it succeeds.
    #
    #   { "data": { ... } }                                        single
    #   { "data": { ... }, "meta": { "cache": { ... } } }          single_with_cache (one assignment)
    #   { "data": [ ... ], "meta": { "pagination": { ... } } }     collection
    #   { "data": [ ... ] }                                        list (generate_fields)
    #   { "error": { "status": 404, "messages": "..." } }          error
    #
    # A type is a Symbol from TYPES; a trailing `?` allows null
    # (`:string?`). A Hash is an object with exactly those keys, a one-element
    # Array a list of that element. `:foreign_identifier` marks the numeric id
    # of another PermissionForge record, which the API's URLs do not take
    # under `api_record_identifier = :uuid`: its value is unchanged (the
    # record's id), and the key after it, `:foreign_uuid`, names the same
    # record by its uuid (`permission_set_id`, `permission_set_uuid`:
    # Serializers::BaseSerializer.reference) — answer-only: no endpoint
    # takes it, the `_id` key changes a reference.
    #
    # test/permission_forge/api/envelope_schema_test.rb asserts every route,
    # in every error class, against this module and every serializer's keys
    # against PAYLOADS; `rake docs:api` renders the json samples of
    # docs/admin-api.md from it (Docs::ApiSamples).
    #
    # @api private
    module Schema
      UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
      # What a value of each type is, as the JSON answer carries it.
      TYPES = {
        integer: ->(value) { value.is_a?(Integer) },
        string: ->(value) { value.is_a?(String) },
        boolean: ->(value) { [true, false].include?(value) },
        uuid: ->(value) { value.is_a?(String) && value.match?(UUID) },
        time: ->(value) { value.is_a?(String) && Check.iso8601?(value) },
        foreign_identifier: ->(value) { value.is_a?(Integer) },
        foreign_uuid: ->(value) { value.is_a?(String) && value.match?(UUID) },
        host_key: ->(value) { value.is_a?(Integer) || value.is_a?(String) },
        host_key_list: ->(value) { value.is_a?(Array) && value.all? { |item| item.is_a?(Integer) || item.is_a?(String) } },
        string_list: ->(value) { value.is_a?(Array) && value.all?(String) },
        object: ->(value) { value.is_a?(Hash) },
        # `messages` of a 422: a field (a parameter, an attribute, `base`)
        # mapped to its messages.
        field_messages: lambda { |value|
          value.is_a?(Hash) && !value.empty? &&
            value.all? { |field, list| field.is_a?(String) && list.is_a?(Array) && !list.empty? && list.all?(String) }
        }
      }.freeze

      # One serializer's payload per entry, named after the serializer
      # (`permission_set` = Serializers::PermissionSetSerializer), keys in
      # the serializer's order.
      PAYLOADS = {
        permission_set: {
          id: :integer, uuid: :uuid, name: :string, description: :string?,
          is_active: :boolean, is_editable: :boolean, is_muting: :boolean,
          requires_session_flag: :string?, allowed_ips: :string?, allowed_ip_list: :string_list,
          allowed_hours_start: :integer?, allowed_hours_end: :integer?,
          permission_set_group_id: :foreign_identifier?, permission_set_group_uuid: :foreign_uuid?, created_at: :time, updated_at: :time
        },
        resource: {
          id: :integer, uuid: :uuid, permission_set_id: :foreign_identifier, permission_set_uuid: :foreign_uuid,
          name: :string, description: :string?, is_active: :boolean, is_editable: :boolean,
          read_access: :boolean, create_access: :boolean, edit_access: :boolean, delete_access: :boolean,
          view_all: :boolean, modify_all: :boolean,
          created_at: :time, updated_at: :time
        },
        resource_field: {
          id: :integer, uuid: :uuid, resource_id: :foreign_identifier, resource_uuid: :foreign_uuid,
          name: :string, label: :string, description: :string?, is_active: :boolean, is_editable: :boolean,
          read_access: :boolean, edit_access: :boolean, mask_access: :boolean, mask_strategy: :string,
          created_at: :time, updated_at: :time
        },
        resource_action: {
          id: :integer, uuid: :uuid, resource_id: :foreign_identifier, resource_uuid: :foreign_uuid,
          name: :string, label: :string?, description: :string?, is_permitted: :boolean, is_active: :boolean,
          created_at: :time, updated_at: :time
        },
        permission_set_rule: {
          id: :integer, uuid: :uuid, permission_set_id: :foreign_identifier, permission_set_uuid: :foreign_uuid,
          resource_id: :foreign_identifier, resource_uuid: :foreign_uuid,
          name: :string, failure_message: :string?, join_type: :string?,
          field_name: :string, field_value: :string, field_accessor_path: :string?,
          operator: :string, include_nulls: :boolean, is_active: :boolean, is_editable: :boolean,
          created_at: :time, updated_at: :time
        },
        permission_set_user: {
          id: :integer, uuid: :uuid, permission_set_id: :foreign_identifier, permission_set_uuid: :foreign_uuid,
          user_id: :host_key, expires_at: :time?, created_at: :time, updated_at: :time
        },
        audit_event: {
          id: :integer, uuid: :uuid, occurred_at: :time, event: :string, category: :string,
          actor_type: :string, actor_id: :string?, actor_label: :string?, source: :string,
          record_type: :string?, record_id: :string?, record_uuid: :string?, record_label: :string?,
          permission_set_id: :foreign_identifier?, permission_set_uuid: :string?, subject_user_id: :string?,
          data: :object, reason: :string?, request_id: :string?, ip: :string?, correlation_id: :string?, created_at: :time
        },
        permission_set_group: {
          id: :integer, uuid: :uuid, name: :string, description: :string?, is_active: :boolean, is_editable: :boolean,
          created_at: :time, updated_at: :time
        },
        permission_set_group_user: {
          id: :integer, uuid: :uuid, permission_set_group_id: :foreign_identifier, permission_set_group_uuid: :foreign_uuid,
          user_id: :host_key, created_at: :time, updated_at: :time
        }
      }.freeze

      # Cache::Outcome as the API answers it: what one change did to the
      # cached permissions (a bulk assignment, one assignment).
      CACHE = { confirmed: :boolean?, process_local: :boolean, unconfirmed: :integer?, in_request: :boolean }.freeze

      # The payloads a controller builds itself (no serializer).
      RESULTS = {
        stats: {
          permission_sets_count: :integer, active_sets_count: :integer, resources_count: :integer,
          rules_count: :integer, groups_count: :integer, users_count: :integer
        },
        # Services::BulkPermissionSetAssignment's counts, its Cache::Outcome
        # and the ids that named nobody. `invalidated` is null inside a
        # caller's transaction.
        bulk_assignment: {
          assigned: :integer, revoked: :integer, invalidated: :integer?,
          cache: CACHE,
          skipped: :host_key_list
        }
      }.freeze

      PAGINATION = { page: :integer, per_page: :integer, total_count: :integer }.freeze

      # The success envelopes, each around a payload spec.
      ENVELOPES = {
        single: ->(payload) { { data: payload } },
        # One assignment made or revoked, and its Cache::Outcome.
        single_with_cache: ->(payload) { { data: payload, meta: { cache: CACHE } } },
        collection: ->(payload) { { data: [payload], meta: { pagination: PAGINATION } } },
        list: ->(payload) { { data: [payload] } }
      }.freeze

      # What `messages` is under each error status. A 422 maps fields to
      # their messages; the others carry one sentence.
      ERRORS = { 400 => :string, 401 => :string, 403 => :string, 404 => :string, 422 => :field_messages }.freeze

      # The answers without a body, and when: a delete (204), the 401 while
      # config.api_auth is not set, the 404 while config.api_enabled is off
      # (it does not reveal that an API exists under the mount).
      BODILESS = { 204 => :deleted, 401 => :api_auth_not_set, 404 => :api_disabled }.freeze

      # What an endpoint answers when it succeeds: its status, envelope and
      # payload (PAYLOADS or RESULTS); the catch-all is always its 404.
      Endpoint = Data.define(:status, :envelope, :payload)

      crud = lambda do |name|
        { 'index' => Endpoint.new(200, :collection, name), 'show' => Endpoint.new(200, :single, name),
          'create' => Endpoint.new(201, :single, name), 'update' => Endpoint.new(200, :single, name),
          'destroy' => Endpoint.new(204, nil, nil) }
      end
      prefixed = ->(controller, actions) { actions.transform_keys { |action| "#{controller}##{action}" } }

      # Keyed by "controller#action", the controller under permission_forge/api/.
      ENDPOINTS = {
        'dashboard#show' => Endpoint.new(200, :single, :stats),
        'audit_events#index' => Endpoint.new(200, :collection, :audit_event),
        'audit_events#show' => Endpoint.new(200, :single, :audit_event),
        **prefixed.call('permission_sets', crud.call(:permission_set).merge('clone' => Endpoint.new(201, :single, :permission_set))),
        **prefixed.call('resources', crud.call(:resource).merge('generate_fields' => Endpoint.new(201, :list, :resource_field))),
        **prefixed.call('resource_fields', crud.call(:resource_field)),
        **prefixed.call('resource_actions', crud.call(:resource_action)),
        **prefixed.call('permission_set_rules', crud.call(:permission_set_rule)),
        **prefixed.call('permission_set_users', crud.call(:permission_set_user).slice('index')
                                                  .merge('create' => Endpoint.new(201, :single_with_cache, :permission_set_user),
                                                         'destroy' => Endpoint.new(200, :single_with_cache, :permission_set_user),
                                                         'bulk' => Endpoint.new(200, :single, :bulk_assignment))),
        **prefixed.call('permission_set_groups', crud.call(:permission_set_group)
                                                   .merge('clone' => Endpoint.new(201, :single, :permission_set_group))),
        **prefixed.call('permission_set_group_users', crud.call(:permission_set_group_user).slice('index', 'create', 'destroy')),
        'unmatched_routes#show' => Endpoint.new(404, :error, nil)
      }.freeze

      module_function

      # @param name [Symbol] a PAYLOADS or RESULTS entry
      # @return [Hash{Symbol => Symbol, Hash}] the keys and their types
      def payload(name)
        PAYLOADS.fetch(name) { RESULTS.fetch(name) }
      end

      # @return [Array<Symbol>] the keys of a payload, in order
      def payload_keys(name) = payload(name).keys

      # @return [Array<Symbol>] the keys of a payload that hold another record's numeric id
      #   (each followed by its `:foreign_uuid` key)
      def foreign_identifiers(name)
        payload(name).select { |_key, type| type.is_a?(Symbol) && base_type(type) == :foreign_identifier }.keys
      end

      # The spec of a success envelope around a payload.
      def envelope(kind, payload_name)
        ENVELOPES.fetch(kind).call(payload(payload_name))
      end

      # The spec of an error answer under `status`.
      def error_envelope(status)
        { error: { status: [:exactly, status], messages: ERRORS.fetch(status) } }
      end

      # An error answer: the body the API renders for `status`.
      #
      # @return [Hash]
      def error_body(status, messages)
        { 'error' => { 'status' => status, 'messages' => messages } }
      end

      # What is wrong with a parsed JSON answer of an endpoint's success.
      #
      # @param endpoint [Endpoint]
      # @param body [Hash, nil] the parsed body (nil when there is none)
      # @return [Array<String>] empty when it matches
      def success_problems(endpoint, body)
        return error_problems(endpoint.status, body) if endpoint.envelope == :error
        return body.nil? ? [] : ["#{endpoint.status}: a body where none is declared"] if endpoint.envelope.nil?

        problems(body, envelope(endpoint.envelope, endpoint.payload))
      end

      # What is wrong with a parsed JSON error answer under `status`; nil
      # (no body) only where BODILESS declares it.
      #
      # @return [Array<String>]
      def error_problems(status, body)
        return BODILESS.key?(status) ? [] : ["#{status}: no body, and BODILESS does not declare one"] if body.nil?
        return ["#{status}: not an error status of the schema (#{ERRORS.keys.join(', ')})"] unless ERRORS.key?(status)

        problems(body, error_envelope(status))
      end

      # What is wrong with `value` against `spec`, one message per problem,
      # each with its JSON path (Check).
      #
      # @return [Array<String>]
      def problems(value, spec, path = '$') = Check.problems(value, spec, path)

      def base_type(type) = type.to_s.delete_suffix('?').to_sym

      # Walks a parsed answer along a spec (a Hash, a one-element Array, a
      # type Symbol, or [:exactly, value]).
      #
      # @api private
      module Check
        # A value of the answer and its JSON path.
        Node = Data.define(:value, :path) do
          def refused(expected) = ["#{path}: expected #{expected}, got #{value.inspect[0, 60]}"]
          def at(key) = "#{path}.#{key}"
        end

        module_function

        def problems(value, spec, path)
          node = Node.new(value, path)
          case spec
          when Hash then object_problems(node, spec)
          when Array then spec.first == :exactly ? exact_problems(node, spec.last) : list_problems(node, spec.first)
          else type_problems(node, spec)
          end
        end

        def object_problems(node, spec)
          value = node.value
          return node.refused('an object') unless value.is_a?(Hash)

          keys = value.keys.map(&:to_s)
          key_problems(node, keys, spec.keys.map(&:to_s)) + value_problems(node, spec)
        end

        # The values of the declared keys the answer has, each against its spec.
        def value_problems(node, spec)
          value = node.value
          spec.flat_map { |key, inner| value.key?(key.to_s) ? problems(value[key.to_s], inner, node.at(key)) : [] }
        end

        # Keys the answer has and the spec does not, and the reverse.
        def key_problems(node, keys, expected)
          (keys - expected).map { |key| "#{node.at(key)}: not declared in Api::Schema" } +
            (expected - keys).map { |key| "#{node.at(key)}: missing" }
        end

        def list_problems(node, spec)
          value = node.value
          return node.refused('a list') unless value.is_a?(Array)

          value.each_with_index.flat_map { |item, index| problems(item, spec, "#{node.path}[#{index}]") }
        end

        def exact_problems(node, expected)
          node.value == expected ? [] : node.refused(expected.inspect)
        end

        def type_problems(node, type)
          value = node.value
          return [] if value.nil? && type.to_s.end_with?('?')

          TYPES.fetch(Schema.base_type(type)).call(value) ? [] : node.refused(type)
        end

        def iso8601?(text)
          Time.iso8601(text)
          true
        rescue ArgumentError
          false
        end
      end
    end
  end
end
