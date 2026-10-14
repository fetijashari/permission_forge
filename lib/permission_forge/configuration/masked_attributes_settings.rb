# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Configuration for {PermissionForge::Concerns::MaskedAttributes} model-level enforcement.
    #
    # @api public
    module MaskedAttributesSettings
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
      # mailer, the console, a resolver that returns nil). Nothing else
      # governs masking without a user: nil_user_strategy is about rows,
      # response_filter_nil_user_strategy about FiltersResponseAttributes.
      #
      #   :bypass — every getter returns the stored value (default)
      #   :hide   — every guarded attribute reads as hidden_attribute_value:
      #             getters, read_attribute, `[]`, attributes, as_json and
      #             the wrapped virtual readers and store accessors. The
      #             primary key and the raw paths (read_attribute_before_type_cast,
      #             pluck) are untouched, as for a signed-in user. Code that
      #             reads masked models with no user then sees hidden values:
      #             set the current user in those jobs and mailers. The user
      #             model (user_class and its subclasses) is exempt: sign-in
      #             reads it before anyone is signed in (encrypted_password,
      #             confirmation_token, lockable counters).
      attr_accessor :masked_attributes_nil_user_strategy

      # @return [Boolean] whether the strategy is :hide (whatever the model)
      def hide_masked_attributes_without_user?
        @masked_attributes_nil_user_strategy.to_s == 'hide'
      end

      # The one decision of whether a record of klass hides its guarded
      # attributes when nobody is signed in: under :hide, every model but the
      # user model.
      #
      # @param klass [Class]
      # @return [Boolean]
      def hide_masked_attributes_without_user_for?(klass)
        hide_masked_attributes_without_user? && !user_model_class?(klass)
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
