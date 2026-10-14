module PermissionForge
  module Concerns
    # Field-level mask checks.
    # Depends on PermissionCacheAccessor for pf_resource_name_permissions.
    #
    # @api public
    module FieldMaskChecker
      extend ActiveSupport::Concern

      # @param resource [Symbol, String] resource name
      # @param field_name [Symbol, String] field name
      # @return [Boolean] true if the field should be masked
      #
      # Fail-closed for unconfigured fields: when the field has no entry in the
      # permission hash, the answer follows `unconfigured_field_strategy` — a
      # blocking or mask-all strategy reports the field as masked rather than
      # defaulting to "not masked" (which would leak plaintext).
      def masked_field?(resource, field_name)
        field = field_permissions(resource, field_name)
        return field[:mask_access] == true if field

        %i[block mask_all].include?(PermissionForge.configuration.unconfigured_field_strategy)
      end

      # @param resource [Symbol, String] resource name
      # @param field_name [Symbol, String] field name
      # @return [String] mask strategy (e.g., 'full', 'email', 'last4')
      def mask_strategy_for(resource, field_name)
        field = field_permissions(resource, field_name)
        field&.dig(:mask_strategy) || 'full'
      end

      # @param resource [Symbol, String] resource name
      # @param field_name [Symbol, String] field name
      # @return [Hash, nil] field permission hash with :read_access, :edit_access, :mask_access, :mask_strategy
      def field_permissions(resource, field_name)
        entry = pf_resource_name_permissions(resource)
        return if entry.blank?

        field_name = field_name.to_sym
        entry.dig(:fields, field_name)
      end
    end
  end
end
