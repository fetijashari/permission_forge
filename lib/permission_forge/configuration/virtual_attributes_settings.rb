# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options for virtual (non-column) fields: names a model declares through
    # `extra_fields_method`, plus names the admin can discover.
    #
    # @api public
    module VirtualAttributesSettings
      EXTRA_FIELDS_DEFAULT_ACCESS = %i[grant unconfigured].freeze

      # What a declared virtual field gets when no ResourceField row configures it:
      #
      #   :grant        — readable and editable, unmasked (default, backward-compatible)
      #   :unconfigured — no implicit entry; the field follows unconfigured_field_strategy
      #                   until an admin gives it a level (fail closed with :block)
      #
      # A String is taken as its Symbol; any other value raises
      # ConfigurationError (StrategyValues).
      attr_accessor :extra_fields_default_access

      # When true, the admin also lists attribute-API attributes and
      # store_accessor keys as virtual fields. Discovered names never get
      # implicit access — they stay unconfigured until an admin sets a level.
      # Default: false.
      attr_accessor :virtual_field_discovery

      # Model-level masking of virtual readers (methods, store accessors,
      # attribute-API attributes), on top of the column masking MaskedAttributes
      # already does. Off by default: the model's own callbacks and validations
      # then see the masked value too (see pf_without_virtual_masking).
      #
      #   false / nil            — off; virtual fields are enforced only by
      #                            PermitsAttributes and FiltersResponseAttributes (default)
      #   :auto / true           — every model that has MaskedAttributes
      #   ['Customer', 'Order']  — only these models
      attr_accessor :mask_virtual_attributes

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_virtual_attributes_defaults
        @extra_fields_default_access = :grant
        @virtual_field_discovery = false
        @mask_virtual_attributes = false
      end

      # @return [Boolean] whether declared virtual fields get the implicit
      #   read + edit entry. Only the exact :grant value grants.
      def grant_extra_fields_by_default?
        extra_fields_default_access.to_s == 'grant'
      end

      # @param model_name [String, Symbol, Class]
      # @return [Boolean] whether virtual readers of this model are masked.
      def mask_virtual_attributes_for?(model_name)
        setting = mask_virtual_attributes
        return false if [false, nil].include?(setting)
        return setting.map(&:to_s).include?(model_name.to_s) if setting.is_a?(Array)

        [true, :auto, 'auto'].include?(setting)
      end
    end
  end
end
