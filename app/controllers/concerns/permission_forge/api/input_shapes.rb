# frozen_string_literal: true

module PermissionForge
  module Api
    # The one shape table of the JSON API's attribute sections
    # (`{ "permission_set": { ... } }`): what each attribute is taken in,
    # read through BaseController#pf_record_attributes by every endpoint
    # that creates or updates a record. A value of another shape is a 422
    # keyed by the attribute, every wrong attribute of the request named
    # (`{ "is_active": ["must be true or false"] }`): never dropped, never
    # cast into something else, never a 500. Through 0.15.0-rc strong
    # parameters dropped a list or an object sent for a scalar with a log
    # line, and ActiveModel cast what remained: "nope" was true, a JSON
    # `true` for a name stored "t" (field test round 7, d-api #54 / #59).
    #
    # An attribute's shape is its column type's (BY_TYPE: what the model
    # casts it to, `type_for_attribute`), unless DECLARED names one:
    #
    # - boolean: ParamShapes.boolean (true, false, 1, 0, and the words
    #   true/false/t/f/on/off/1/0 in any case), stored as true or false;
    # - text: a String;
    # - integer: an Integer or a String of digits;
    # - the activation conditions: `allowed_ips` a String or a list of
    #   Strings (stored with commas; a list with no entry is refused),
    #   an hour an integer or digits, a session flag a String — `""` clears
    #   each;
    # - a rule's `field_value`: a String, or a JSON number or boolean (stored
    #   as its text: `5` → "5", `true` → "true"); a list of them, none with a
    #   comma, only for an operator that takes several values (`in`,
    #   `not_in`, `between`: Operators::ValueTyping::SEVERAL), stored joined
    #   with commas;
    # - a reference (`permission_set_group_id`, `permission_set_group_uuid`):
    #   taken as sent, then read by BaseController#with_reference_id (the id
    #   or uuid of a record; null or "" clears it; anything else a 422 keyed
    #   by it).
    #
    # `null` is passed to the model for every attribute: a nullable column
    # is cleared, a NOT NULL one answers its own validation (422 keyed by
    # the attribute). An attribute whose type has no shape here (none of the
    # gem's: the input_shapes test checks) is passed on as sent.
    #
    # @api private
    module InputShapes
      # How one shape reads a value: the value to store, or a Refusal.
      Refusal = Data.define(:message)

      # The 422 of a section with values of the wrong shape: every attribute
      # and its message.
      #
      # @api private
      class Refused < ParamShapes::InvalidParam
        # @return [Hash{String => Array<String>}]
        attr_reader :messages

        # @param messages [Hash{String => Array<String>}] at least one
        def initialize(messages)
          @messages = messages
          param, (detail, *) = messages.first
          super(param, detail)
        end
      end

      # What a rule needs to read its value: the operator it is compared
      # with (the request's, else the stored rule's, else the column default).
      Context = Data.define(:operator)

      # The shape of each column type the API writes.
      BY_TYPE = { boolean: :boolean, string: :text, text: :text, integer: :integer }.freeze

      # The attributes whose shape is not their column type's.
      DECLARED = {
        'allowed_ips' => :ip_list, 'requires_session_flag' => :flag,
        'allowed_hours_start' => :hour, 'allowed_hours_end' => :hour,
        'field_value' => :rule_value, 'permission_set_group_id' => :reference, 'permission_set_group_uuid' => :reference
      }.freeze

      # The shapes whose blank String ("") is no value (null): a condition
      # or a reference is cleared with it.
      BLANK_CLEARS = %i[ip_list flag hour reference].freeze

      # Each shape's reader, (value, Context) → the value to store, or a
      # Refusal (its message key under permission_forge.api.errors).
      SHAPES = {
        boolean: ->(value, _) { ParamShapes.boolean(value).then { |read| read.nil? ? Refusal.new('boolean_invalid') : read } },
        text: ->(value, _) { value.is_a?(String) ? value : Refusal.new('text_shape') },
        integer: ->(value, _) { whole_number?(value) ? value : Refusal.new('integer_shape') },
        hour: ->(value, _) { whole_number?(value) ? value : Refusal.new('hour_shape') },
        flag: ->(value, _) { value.is_a?(String) ? value : Refusal.new('flag_shape') },
        ip_list: ->(value, _) { ip_list(value) },
        rule_value: ->(value, context) { rule_value(value, context) },
        reference: ->(value, _) { value },
        as_is: ->(value, _) { value }
      }.freeze

      # A whole number as an hour or a count is sent: an Integer, or digits
      # with an optional minus sign and surrounding white space.
      WHOLE_NUMBER = /\A\s*-?\d+\s*\z/

      module_function

      # The `keys` of `attrs` it has, each read in its shape.
      #
      # @param attrs [ActionController::Parameters] the section (NUL bytes dropped)
      # @param model [Class] the model the section writes
      # @param keys [Array<Symbol, String>] the attributes the endpoint takes
      # @param record [ActiveRecord::Base, nil] the record an update changes
      #   (a rule's stored operator reads its value)
      # @return [ActiveSupport::HashWithIndifferentAccess]
      # @raise [Refused] naming every attribute of the wrong shape
      def call(attrs, model, keys, record: nil)
        context = Context.new(operator: operator_of(attrs, model, record))
        read = keys.map(&:to_s).select { |key| attrs.key?(key) }.to_h { |key| [key, read_value(attrs[key], shape_of(model, key), context)] }
        refused = read.select { |_, value| value.is_a?(Refusal) }
        raise Refused, messages(refused) if refused.any?

        read.with_indifferent_access
      end

      # One parameter outside a section (a copy's `name`) in `shape`; nil
      # is no value.
      #
      # @raise [Refused] keyed by `key` for another shape
      # @return [void]
      def check!(key, value, shape)
        read = value.nil? ? nil : SHAPES.fetch(shape).call(value, nil)
        raise Refused, messages(key.to_s => read) if read.is_a?(Refusal)
      end

      # The shape `key` of `model` is read in: DECLARED, else its type's
      # (BY_TYPE), else :as_is.
      #
      # @return [Symbol] a SHAPES key
      def shape_of(model, key)
        DECLARED.fetch(key.to_s) { BY_TYPE.fetch(model.type_for_attribute(key.to_s).type, :as_is) }
      end

      # The field-keyed messages of the Refusals.
      def messages(refusals)
        refusals.transform_values { |refusal| [I18n.t("permission_forge.api.errors.#{refusal.message}")] }
      end

      def read_value(value, shape, context)
        value = nil if value == '' && BLANK_CLEARS.include?(shape)
        return value if value.nil?

        SHAPES.fetch(shape).call(value, context)
      end

      def operator_of(attrs, model, record)
        operator = attrs['operator'] if attrs.key?('operator')
        return operator if operator.is_a?(String)
        return record.operator if record.respond_to?(:operator)

        model.column_defaults['operator']
      end

      def whole_number?(value)
        value.is_a?(Integer) || (value.is_a?(String) && value.match?(WHOLE_NUMBER))
      end

      # A String (commas, newlines or spaces between the entries) or a list
      # of Strings, the entries joined with commas by the one parser
      # (ActivationConditions). A list with no entry (`[]`, `[""]`, `" , "`)
      # is refused rather than read as "no condition": null (or "") clears.
      def ip_list(value)
        return Refusal.new('ip_list_shape') unless value.is_a?(String) || (value.is_a?(Array) && value.all?(String))

        PermissionForge::ActivationConditions.entries(value).join(',').presence || Refusal.new('ip_list_empty')
      end

      # A rule's value as the text the rule stores (see the module).
      def rule_value(value, context)
        return list_text(value, context.operator) if value.is_a?(Array)

        scalar_text(value) || Refusal.new('field_value_shape')
      end

      # A list joined with commas, for an operator that takes several values;
      # each element a scalar without a comma (the stored text is split at
      # them: Operators::ValueTyping.split).
      def list_text(value, operator)
        typing = PermissionForge::Operators::ValueTyping
        texts = value.map { |element| scalar_text(element) }
        joinable = typing::SEVERAL.include?(typing::SHAPES[operator]) && texts.any? && texts.none? { |text| text.nil? || text.include?(',') }
        joinable ? texts.join(',') : Refusal.new('field_value_shape')
      end

      # The text of a JSON scalar: a String as sent, a number as written
      # (a fraction without an exponent: 1.5 → "1.5"), true / false as
      # "true" / "false"; nil for anything else.
      def scalar_text(value)
        case value
        when String then value
        when Integer, true, false then value.to_s
        when Float then BigDecimal(value.to_s).to_s('F') if value.finite?
        end
      end
      private_class_method :messages, :read_value, :operator_of, :whole_number?, :ip_list, :rule_value, :list_text, :scalar_text
    end
  end
end
