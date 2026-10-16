module PermissionForge
  module Services
    # Decides what value an attribute reader should return for a given user, based on
    # the user's field permissions. Used by {PermissionForge::Concerns::MaskedAttributes}.
    #
    # Returns a `[include?, value]` tuple so callers can distinguish "omit this key from
    # the hash" from "substitute this value in place." This mirrors the asymmetry between
    # Salesforce's `Security.stripInaccessible()` (omits the field) and a direct getter
    # call (which has to return *something*).
    #
    # @example Single attribute
    #   include?, value = AttributeAccessGuard.call(
    #     resource_name: :Customer, attribute: :email, raw_value: 'a@b.com', user: current_user
    #   )
    #
    # Every decision is reported for the field.access audit event
    # (Audit::FieldAccess), which also calls the legacy on_field_filtered hook:
    # to `observer:` — the frame of the record read in progress, or nil when
    # nobody listens (MaskedAttributes) — or, by default, to whatever read is
    # in progress on this thread (a call of its own is a read of its own).
    #
    # `resource_name:` is one Resource name, or the chain of names the
    # record's class answers to (ResourceChain: its own and its STI
    # ancestors', nearest first). The field is looked up along the chain; the
    # decision is reported under the first name, the record's own.
    #
    # @api private
    class AttributeAccessGuard
      ACTIONS = %i[hidden masked passed bypassed unconfigured].freeze

      # The default observer: Audit::FieldAccess.note.
      STANDALONE = Object.new.freeze

      # Called on every guarded read: the instance is set up without passing
      # the keywords on a second time (half the cost of `new(...).call`).
      # rubocop:disable Metrics/ParameterLists -- model: the record's class, so a read with no user looks up no constant
      def self.call(resource_name:, attribute:, raw_value:, user: nil, observer: STANDALONE, model: nil)
        allocate.decide(resource_name, attribute, raw_value, user, observer, model)
      end

      # @param resource_name [Symbol, String, Array<Symbol>] a name, or the chain
      # @param observer [Audit::FieldAccess::Frame, nil] where decisions go
      # @param model [Class, nil] the record's class (default: the class the
      #   first name names)
      def initialize(resource_name:, attribute:, raw_value:, user: nil, observer: STANDALONE, model: nil)
        assign(resource_name, attribute, raw_value, user, observer)
        @model = model
      end

      # .call on an allocated instance. @api private
      def decide(resource_name, attribute, raw_value, user, observer, model = nil)
        assign(resource_name, attribute, raw_value, user, observer)
        @model = model
        call
      end
      # rubocop:enable Metrics/ParameterLists

      # @return [Array(Boolean, Object)] tuple of (include_in_hash?, value_to_return)
      def call
        return without_user unless @user
        return unconfigured unless field

        return hidden unless field[:read_access]
        return masked if field[:mask_access]

        passed
      end

      private

      def assign(resource_name, attribute, raw_value, user, observer)
        @resource_names = resource_name.is_a?(Array) ? resource_name : resource_name.to_sym
        @resource_name = resource_name.is_a?(Array) ? resource_name.first : @resource_names
        @attribute = attribute.to_sym
        @raw_value = raw_value
        @user = user || PermissionForge.current_user
        @observer = observer
      end

      def field
        return @field if defined?(@field)

        @field = PermissionForge::ResourceChain.field_permissions(@user, @resource_names, @attribute)
      end

      # Without a user there is no entry to decide by:
      # config.masked_attributes_nil_user_strategy says whether every
      # attribute passes (:bypass, the default) or is hidden (:hide) — except
      # on the user model, which sign-in reads before anyone is signed in.
      # The model is the record's class, or else the one the first name of the
      # chain names (an anonymous subclass answers as its base).
      def without_user
        model = @model || @resource_name.to_s.safe_constantize
        PermissionForge.configuration.hide_masked_attributes_without_user_for?(model) ? hidden : bypass
      end

      def bypass
        notify(:bypassed)
        [true, @raw_value]
      end

      def hidden
        notify(:hidden)
        [false, PermissionForge.configuration.hidden_attribute_value]
      end

      def masked
        notify(:masked)
        strategy = field[:mask_strategy] || 'full'
        [true, MaskValue.call(@raw_value, strategy: strategy)]
      end

      def passed
        notify(:passed)
        [true, @raw_value]
      end

      def unconfigured
        # FiltersResponseAttributes.unconfigured_strategy: the one lookup (an unknown key blocks).
        include_field, value = FiltersResponseAttributes.unconfigured_strategy.call(@resource_name.to_s, @attribute, @raw_value)
        notify(:unconfigured)
        [include_field, value]
      end

      def notify(action)
        return if @observer.nil?
        return PermissionForge::Audit::FieldAccess.note(@resource_name, @attribute, action, @user) if @observer.equal?(STANDALONE)

        @observer.add(@resource_name, @attribute, action, @user)
      end
    end
  end
end
