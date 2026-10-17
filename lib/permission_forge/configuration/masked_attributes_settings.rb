# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Configuration for {PermissionForge::Concerns::MaskedAttributes} model-level enforcement.
    #
    # @api public
    module MaskedAttributesSettings
      # The masked_attributes_nil_user_strategy values that hide inside web
      # requests.
      HIDING_NIL_USER_STRATEGIES = %i[hide_in_requests hide].freeze

      # Value returned by MaskedAttributes when read_access is denied. Default: nil.
      attr_accessor :hidden_attribute_value

      # When true (default), MaskedAttributes omits hidden keys from `attributes` /
      # `as_json` / `serializable_hash`. When false, keys are present with hidden_attribute_value.
      attr_accessor :omit_hidden_in_attributes_hash

      # Controls auto-applying MaskedAttributes to host models.
      #
      #   :auto / true                       — apply to every model that has a Resource record (default)
      #   ['Customer', 'Order']              — only apply to these named models
      #   false / nil                        — no auto-apply; dev includes the concern manually
      #
      # Auto-apply runs at engine boot (scanning existing Resource rows) and again
      # whenever a new Resource is created at runtime. Both paths respect this setting.
      attr_accessor :auto_apply_masked_attributes

      # Protects against persisting a masked/hidden value back to the database.
      # MaskedAttributes overrides column getters, so a host callback like
      # `before_save { self.email = email.strip }` would otherwise read the MASKED
      # value and write it back, corrupting the stored data. This guard remembers
      # the exact sentinel handed out for each attribute and, when that same
      # sentinel is written back, prevents the overwrite.
      #
      #   :skip  — silently keep the original stored value (default, safe)
      #   :raise — raise MaskedAttributes::MaskedWriteError (surfaces the bug)
      #   :off   — disable the guard (legacy behavior; risks silent corruption)
      attr_accessor :masked_write_protection

      # What the attribute guard does when there is no current user (a job, a
      # mailer, the console, a public page, a resolver that returns nil).
      # Nothing else governs masking without a user: nil_user_strategy is
      # about rows, response_filter_nil_user_strategy about
      # FiltersResponseAttributes.
      #
      #   :bypass           — every getter returns the stored value (the
      #                       library default). Inside a web request each
      #                       guarded attribute so returned is recorded:
      #                       field.unmasked_without_user (runtime group
      #                       :bypass, once per request per model and
      #                       attribute) and one SECURITY warning per model
      #                       and process in the log.
      #   :hide_in_requests — inside a web request (PermissionForge::WebRequest:
      #                       a public page, a webhook, a controller that
      #                       forgot authentication, the before_actions and
      #                       middlewares that run before sign-in) every
      #                       guarded attribute is hidden as under :hide;
      #                       everywhere else (jobs, rake, runner, the
      #                       console) as :bypass. What the generated
      #                       initializer and config.preset = :strict set.
      #   :hide             — every guarded attribute reads as
      #                       hidden_attribute_value everywhere: getters,
      #                       read_attribute, `[]`, attributes, as_json and
      #                       the wrapped virtual readers and store accessors.
      #                       Code that reads masked models with no user then
      #                       sees hidden values: set the current user in
      #                       those jobs and mailers.
      #
      # Where it hides, the primary key and the raw paths
      # (read_attribute_before_type_cast, pluck) are untouched, as for a
      # signed-in user, and the user model (user_class and its subclasses) is
      # exempt: sign-in reads it before anyone is signed in
      # (encrypted_password, confirmation_token, lockable counters).
      attr_accessor :masked_attributes_nil_user_strategy

      # @return [Boolean] whether the strategy is :hide: hidden everywhere
      #   (whatever the model; ask #hide_masked_attributes_without_user_for?
      #   for a record)
      def hide_masked_attributes_without_user?
        @masked_attributes_nil_user_strategy == :hide
      end

      # @return [Boolean] whether the strategy hides guarded attributes at
      #   least inside web requests (:hide_in_requests or :hide)
      def hide_masked_attributes_without_user_in_requests?
        HIDING_NIL_USER_STRATEGIES.include?(@masked_attributes_nil_user_strategy)
      end

      # The one decision of whether a record of klass hides its guarded
      # attributes when nobody is signed in: under :hide, and under
      # :hide_in_requests inside a web request, every model but the user
      # model.
      #
      # @param klass [Class]
      # @return [Boolean]
      def hide_masked_attributes_without_user_for?(klass)
        masked_attributes_without_user_for(klass) == :hide
      end

      # What the attribute guard does with a read of klass when nobody is
      # signed in, the one definition behind #hide_masked_attributes_without_user_for?:
      #
      #   :hide   — hidden (:hide; :hide_in_requests inside a web request)
      #   :record — returned as stored and recorded (:bypass inside a web
      #             request: field.unmasked_without_user), the reads
      #             :hide_in_requests would hide
      #   :bypass — returned as stored (outside a web request, and always
      #             for the user model)
      #
      # Asked on every guarded read with no user: outside a web request
      # under :bypass or :hide_in_requests it reads one execution-state slot.
      #
      # @param klass [Class]
      # @return [Symbol] :hide, :record or :bypass
      def masked_attributes_without_user_for(klass)
        strategy = @masked_attributes_nil_user_strategy
        return :bypass unless strategy == :hide || PermissionForge::WebRequest.active?
        return :bypass if user_model_class?(klass)

        strategy == :bypass ? :record : :hide
      end

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_masked_attributes_defaults
        @hidden_attribute_value = nil
        @omit_hidden_in_attributes_hash = true
        @auto_apply_masked_attributes = :auto
        @masked_write_protection = :skip
        @masked_attributes_nil_user_strategy = :bypass
      end
    end
  end
end
