# frozen_string_literal: true

require 'json'
require 'i18n'
require 'active_support/json'
require 'active_support/core_ext/object/json'
require 'active_support/core_ext/string/inflections'

module PermissionForge
  module Docs
    # The ```json sample=<name> blocks of docs/admin-api.md, rendered from
    # Api::Schema and the serializers (`bundle exec rake docs:api`;
    # docs/api_samples_test.rb fails while the document is stale). A success
    # sample is a serializer's own output for an example record (EXAMPLES,
    # else a value of the key's type), encoded as the API encodes it, inside
    # the envelope the schema declares; an error sample is the schema's error
    # body with the gem's en message. Only the body of a marked block is
    # rewritten: the prose around it is kept as it stands.
    #
    # @api private
    class ApiSamples
      LOCALE_FILE = File.expand_path('../../../config/locales/permission_forge.en.yml', __dir__)
      CREATED = Time.utc(2026, 3, 10, 12, 0, 0)
      UPDATED = Time.utc(2026, 3, 12, 9, 30, 0)

      # A value for a key no EXAMPLES entry gives, by its type.
      TYPE_EXAMPLES = {
        integer: 1, string: 'text', boolean: true, uuid: '00000000-0000-4000-8000-000000000001', time: CREATED,
        foreign_identifier: 1, host_key: 42, host_key_list: [], string_list: [], object: {}
      }.freeze

      # The example record of each payload a sample shows.
      EXAMPLES = {
        permission_set: {
          id: 12, uuid: 'd2b4c7e1-5a3f-4b8e-9c6d-1f2a3b4c5d6e', name: 'Sales Team', description: 'Read and edit customers',
          is_active: true, is_editable: true, is_muting: false, requires_session_flag: nil,
          allowed_ips: '203.0.113.0/24', allowed_ip_list: ['203.0.113.0/24'], allowed_hours_start: nil, allowed_hours_end: nil,
          permission_set_group_id: 3, created_at: CREATED, updated_at: UPDATED
        },
        permission_set_group: {
          id: 3, uuid: '8a6f2c1d-3e4b-4f5a-8b7c-9d0e1f2a3b4c', name: 'Sales', description: nil,
          is_active: true, is_editable: true, created_at: CREATED, updated_at: CREATED
        },
        audit_event: {
          id: 481, uuid: '5c1e9a7b-2d4f-4e6a-9b8c-0d1e2f3a4b5c', occurred_at: Time.utc(2026, 9, 14, 8, 12, 44.120391r),
          event: 'assignment.revoked', category: 'change', actor_type: 'user', actor_id: '7', actor_label: 'Ada Admin',
          source: 'admin_ui', record_type: 'PermissionForge::PermissionSetUser', record_id: '93',
          record_uuid: 'a77f3b2c-1d4e-4f5a-8b6c-7d8e9f0a1b2c', record_label: 'Bo Brandt',
          permission_set_id: 12, permission_set_uuid: 'd2b4c7e1-5a3f-4b8e-9c6d-1f2a3b4c5d6e', subject_user_id: '31',
          data: { 'snapshot' => { 'user_id' => 31, 'expires_at' => nil } }, reason: 'left the team',
          request_id: '6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d', ip: '203.0.113.9',
          correlation_id: '0b8c7d6e-5f4a-4b3c-9d2e-1f0a9b8c7d6e', created_at: Time.utc(2026, 9, 14, 8, 12, 44.121002r)
        }
      }.freeze

      # The 422s an input error answers, one per line of `input_errors`:
      # [field, en key].
      INPUT_ERRORS = [
        %w[expires_at api.errors.not_iso8601_time], %w[permission_set api.errors.section_missing],
        %w[bulk_action api.errors.bulk_action_invalid], %w[user_ids api.errors.user_ids_missing],
        %w[user_id api.errors.user_not_found], %w[grant_all api.errors.boolean_invalid],
        %w[is_active api.errors.boolean_invalid], %w[name api.errors.text_shape],
        %w[field_value api.errors.field_value_shape],
        %w[base api.errors.field_generation_failed]
      ].freeze

      # One sample: how it is laid out (`:pretty`, `:inline` on one line,
      # `:lines` one inline body per line), the schema it follows
      # ([:single | :collection | :list, payload] or [:error, status]) and how
      # it is built (called with the ApiSamples).
      Sample = Data.define(:style, :schema, :build) do
        def error? = schema.first == :error
      end

      SAMPLES = {
        'permission_set' => Sample.new(:pretty, %i[single permission_set], ->(_) { Example.envelope(:single, :permission_set) }),
        'permission_set_group_collection' => Sample.new(:pretty, %i[collection permission_set_group],
                                                        ->(_) { Example.envelope(:collection, :permission_set_group) }),
        'audit_event_collection' => Sample.new(:pretty, %i[collection audit_event],
                                               ->(_) { Example.envelope(:collection, :audit_event, per_page: 100) }),
        'validation_error' => Sample.new(:pretty, [:error, 422], ->(_) { Text.error(422, 'name' => ['validations.name_blank']) }),
        'not_found' => Sample.new(:pretty, [:error, 404], ->(_) { Text.error(404, 'api.errors.not_found') }),
        'route_not_found' => Sample.new(:inline, [:error, 404], ->(_) { Text.error(404, 'api.errors.route_not_found') }),
        'input_errors' => Sample.new(:lines, [:error, 422],
                                     ->(_) { INPUT_ERRORS.map { |field, key| Text.error(422, field => [key]) } }),
        'body_unreadable' => Sample.new(:inline, [:error, 400], ->(_) { Text.error(400, 'api.errors.body_unreadable') }),
        'action_name_invalid' => Sample.new(:inline, [:error, 422], ->(_) { Text.error(422, 'name' => ['errors.admin.action_format']) })
      }.freeze

      # The gem's en messages, in the error body the schema declares.
      module Text
        module_function

        # An error body whose messages are the en texts of `messages`: a
        # key, or a field mapped to keys.
        def error(status, messages)
          texts = messages.is_a?(Hash) ? messages.transform_values { |keys| keys.map { |key| t(key) } } : t(messages)
          Api::Schema.error_body(status, texts)
        end

        # The gem's en text of `permission_forge.<key>`.
        def t(key)
          I18n.load_path |= [LOCALE_FILE] unless I18n.load_path.any? { |path| path.to_s == LOCALE_FILE }
          I18n.t("permission_forge.#{key}", locale: :en, raise: true)
        end
      end

      # A serializer's own output for an example record, in its envelope.
      module Example
        module_function

        # A success envelope around the example record of `payload`, as the
        # API encodes it (`render json:`: times in ISO 8601).
        def envelope(kind, payload, per_page: Configuration.new.api_default_per_page)
          data = JSON.parse(ActiveSupport::JSON.encode(serialized(payload)))
          case kind
          when :single then { 'data' => data }
          when :list then { 'data' => [data] }
          when :collection then { 'data' => [data], 'meta' => { 'pagination' => { 'page' => 1, 'per_page' => per_page, 'total_count' => 1 } } }
          end
        end

        # @raise [ArgumentError] for a serializer key Api::Schema does not declare
        def serialized(payload)
          serializer = Api::Serializers.const_get("#{payload.to_s.camelize}Serializer")
          fields = Api::Schema.payload(payload)
          declared!(serializer, fields.keys)
          serializer.new(record(payload, fields)).as_json
        end

        def declared!(serializer, keys)
          undeclared = serializer.attribute_names - keys
          return if undeclared.empty?

          raise ArgumentError, "#{serializer.name.demodulize} answers #{undeclared.join(', ')}, which Api::Schema does not declare"
        end

        # EXAMPLES' values for `payload`, else a value of each key's type.
        def record(payload, fields)
          examples = EXAMPLES.fetch(payload, {})
          values = fields.to_h { |key, type| [key, examples.fetch(key) { TYPE_EXAMPLES.fetch(type.to_s.delete_suffix('?').to_sym) }] }
          Struct.new(*values.keys, keyword_init: true).new(**values)
        end
      end

      # How a block lays out its JSON.
      module Layout
        module_function

        # Indented two spaces; a list of scalars on one line.
        def pretty(value, indent = 0)
          case value
          when Hash
            entries = value.map { |key, inner| "#{JSON.generate(key.to_s)}: #{pretty(inner, indent + 2)}" }
            value.empty? ? '{}' : nested('{}', entries, indent)
          when Array then scalars?(value) ? inline(value) : nested('[]', value.map { |item| pretty(item, indent + 2) }, indent)
          else JSON.generate(value)
          end
        end

        # `brackets` is the pair ("{}" or "[]") around the entries, one per line.
        def nested(brackets, entries, indent)
          pad = ' ' * indent
          "#{brackets[0]}\n#{entries.map { |entry| "#{pad}  #{entry}" }.join(",\n")}\n#{pad}#{brackets[1]}"
        end

        def scalars?(list) = list.none? { |item| item.is_a?(Hash) || item.is_a?(Array) }

        # One line: `{ "key": value }`, `[a, b]`.
        def inline(value)
          case value
          when Hash then value.empty? ? '{}' : "{ #{value.map { |key, inner| "#{JSON.generate(key.to_s)}: #{inline(inner)}" }.join(', ')} }"
          when Array then "[#{value.map { |item| inline(item) }.join(', ')}]"
          else JSON.generate(value)
          end
        end
      end

      # @param document [String] docs/admin-api.md as it stands
      # @param blocks [Array] its fenced blocks, as test/support/doc_blocks.rb parses them
      #   (each with #file, #line, #body and #sample)
      def initialize(document:, blocks:)
        @document = document
        @blocks = blocks.select(&:sample)
      end

      # The document with the body of every sample block regenerated.
      #
      # @raise [ArgumentError] for a sample= naming no sample, or a serializer
      #   key Api::Schema does not declare
      def render
        lines = @document.lines
        @blocks.sort_by(&:line).reverse_each do |block|
          lines[block.line, block.body.lines.size] = text(sample_name(block)).lines
        end
        lines.join
      end

      def stale? = render != @document

      # The JSON value of a sample (an Array of bodies for a `:lines` sample).
      def value(name)
        SAMPLES.fetch(name).build.call(self)
      end

      # The sample laid out as the block holds it, ending in a newline.
      def text(name)
        built = value(name)
        body = case SAMPLES.fetch(name).style
               when :pretty then Layout.pretty(built)
               when :inline then Layout.inline(built)
               when :lines then built.map { |item| Layout.inline(item) }.join("\n")
               end
        "#{body}\n"
      end

      # What is wrong with a sample against Api::Schema.
      #
      # @return [Array<String>]
      def problems(name)
        sample = SAMPLES.fetch(name)
        kind, detail = sample.schema
        spec = kind == :error ? Api::Schema.error_envelope(detail) : Api::Schema.envelope(kind, detail)
        items = sample.style == :lines ? value(name) : [value(name)]
        items.flat_map { |item| Api::Schema.problems(item, spec) }
      end

      private

      def sample_name(block)
        name = block.sample
        return name if SAMPLES.key?(name)

        raise ArgumentError, "#{block.file}:#{block.line}: sample=#{name} names no sample (#{self.class}::SAMPLES)"
      end
    end
  end
end
