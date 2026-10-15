module PermissionForge
  module Services
    # Filters and masks response attributes based on the current user's field permissions.
    # Fields without read access are removed; fields with mask_access are masked using MaskValue.
    #
    # Fail-closed posture: when a user is present but has NO field permissions for
    # the resource (unmapped resource, cache re-entrancy), every attribute is treated
    # as unconfigured and routed through `unconfigured_field_strategy` (default :block),
    # so an authenticated user never receives raw fields for a resource they lack
    # configured access to. The nil-user case follows `response_filter_nil_user_strategy`.
    #
    # Each call is one read for the field.access audit event
    # (Audit::FieldAccess): the record is named by the resource and the hash's
    # `id`, the hidden, masked and unconfigured keys are listed, and the
    # legacy on_field_filtered hook is called for every configured key, as
    # before.
    #
    # @example
    #   filtered = FiltersResponseAttributes.call(
    #     attributes: { name: 'John', email: 'john@example.com' },
    #     resource_name: 'Customer'
    #   )
    #
    # @api public
    class FiltersResponseAttributes
      # Filters a response hash by the user's field-level read access (does not mutate it).
      # @param attributes [Hash]
      # @param resource_name [String] the model name the fields belong to
      # @param user [Object, nil] defaults to the current user
      # @return [Hash]
      def self.call(attributes:, resource_name:, user: nil)
        new(attributes: attributes, resource_name: resource_name, user: user).call
      end

      def initialize(attributes:, resource_name:, user: nil)
        @attributes = attributes
        @resource_name = resource_name.to_s
        @user = user || PermissionForge.current_user
      end

      # @return [Hash] a new hash without the fields the user may not read, masked where required
      def call
        PermissionForge::Audit::FieldAccess.read(@attributes, @resource_name, record_id: record_id) do |frame|
          @frame = frame
          next handle_nil_user if @user.blank?

          # No early return on blank field_permissions: an authenticated user with no
          # configured access to the resource must still be filtered (fail closed),
          # not handed the raw attributes.
          filter_and_mask
        end
      end

      UNCONFIGURED_FIELD_STRATEGIES = {
        pass_through: ->(_resource_name, _key, value) { [true, value] },
        warn: lambda { |resource_name, key, value|
          Rails.logger.warn("PermissionForge: unconfigured field '#{key}' on #{resource_name} passed through unmasked")
          [true, value]
        },
        mask_all: ->(_resource_name, _key, value) { [true, MaskValue.call(value, strategy: 'full')] },
        block: ->(_resource_name, _key, _value) { [false, nil] }
      }.freeze

      private

      # When there is no current user we cannot evaluate permissions. The behavior
      # is explicit and configurable via `response_filter_nil_user_strategy`:
      #   :bypass — return raw attributes (system/console context; default, backward-compatible)
      #   :block  — return {} (strict fail-closed)
      def handle_nil_user
        if PermissionForge.configuration.response_filter_nil_user_strategy == :block
          note_all(:hidden)
          {}
        else
          note_all(:bypassed)
          @attributes
        end
      end

      # Without a user every key is decided the same way (the hook was never
      # called for these).
      def note_all(action)
        @attributes.each_key { |key| @frame.add(@resource_name, key, action, nil, hook: false) } if @frame
      end

      # The id in the hash, when it has one (the hash's own key, not a reader).
      def record_id
        return unless @attributes.respond_to?(:key?)

        @attributes.key?(:id) ? @attributes[:id] : @attributes['id']
      end

      def filter_and_mask
        @result = {}
        @attributes.each { |key, value| process_field(key, value) }
        @result
      end

      # A key with no entry of its own that is a field's variant (a
      # serializer's `owner_uuid` next to an `owner_id` row) follows that
      # field (FieldVariants.base_entries).
      def process_field(key, value)
        field = field_permissions[key.to_sym] || variant_entries[key.to_s]

        if field.nil?
          include_field, masked_value = handle_unconfigured_field(key, value)
          @result[key] = masked_value if include_field
          @frame&.add(@resource_name, key, :unconfigured, @user, hook: false)
        else
          apply_configured_field(key, value, field)
        end
      end

      def apply_configured_field(key, value, field)
        unless field[:read_access]
          notify_field_filtered(key, :hidden)
          return
        end

        if field[:mask_access]
          @result[key] = MaskValue.call(value, strategy: field[:mask_strategy] || 'full')
          notify_field_filtered(key, :masked)
        else
          @result[key] = value
          notify_field_filtered(key, :passed)
        end
      end

      def notify_field_filtered(field_name, action)
        @frame&.add(@resource_name, field_name, action, @user)
      end

      def handle_unconfigured_field(key, value)
        strategy_key = PermissionForge.configuration.unconfigured_field_strategy
        # Unknown strategy keys fall back to :block (fail closed), never pass-through.
        strategy = UNCONFIGURED_FIELD_STRATEGIES.fetch(strategy_key, UNCONFIGURED_FIELD_STRATEGIES[:block])
        strategy.call(@resource_name, key, value)
      end

      def variant_entries
        @variant_entries ||= PermissionForge::FieldVariants.base_entries(field_permissions)
      end

      # The user's field entries for the resource: those of the model the
      # name names and of its STI ancestors (ResourceChain); {} without any.
      def field_permissions
        @field_permissions ||= PermissionForge::ResourceChain.fields(@user, PermissionForge::ResourceChain.names_for(@resource_name))
      end
    end
  end
end
