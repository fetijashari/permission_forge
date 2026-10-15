module PermissionForge
  module Services
    # Creates a ResourceField for every column of a resource's model (and declared virtual fields
    # under `extra_fields_default_access = :unconfigured`).
    #
    # @api public
    class ResourceFieldGenerator
      # Under `gdpr_defaults` a column that looks like personal data is
      # created masked (readable, not editable). With `grant_all` the caller
      # asked for full access, so no mask is applied: the field is readable
      # and editable in the clear, keeps the recommended mask strategy for
      # when someone masks it, and is still reported as personal data
      # (GdprFieldAuditor, the admin's privacy audit).
      #
      # @param resource [Resource]
      # @param grant_all [Boolean] grant read and edit, unmasked, on the generated fields
      # @return [Array<ResourceField>] the fields created
      def self.call(resource:, grant_all: false)
        new(resource: resource, grant_all: grant_all).call
      end

      def initialize(resource:, grant_all: false)
        @resource = resource
        @grant_all = grant_all
      end

      # All or nothing, under one audit correlation id (an enclosing block's,
      # if any): a field that cannot be saved leaves no field and no event.
      def call
        model_class = @resource.name.safe_constantize
        return [] unless model_class

        fields = PermissionForge::Audit.correlate { PermissionForge::ResourceField.transaction { generate_fields(model_class) } }
        PermissionForge.configuration.record_gdpr_pattern_checksum
        fields
      end

      # A field needs a name: a blank one declared by the model is skipped
      # (and logged) rather than failing "Add resource" / "Sync fields".
      def self.without_blank_names(model_class, names)
        usable = names.reject { |name| name.to_s.strip.empty? }
        skipped = names.size - usable.size
        if skipped.positive?
          Rails.logger&.warn("[PermissionForge] skipped #{skipped} blank field name(s) declared by " \
                             "#{model_class.name}.#{PermissionForge.configuration.extra_fields_method}")
        end
        usable
      end

      private

      def generate_fields(model_class)
        existing_names = @resource.resource_fields.pluck(:name)
        columns = model_class.column_names - ignored_fields + virtual_field_names(model_class) - existing_names

        columns.map do |column_name|
          attrs = build_field_attrs(column_name)
          attrs.merge!(gdpr_default_attrs(column_name)) if PermissionForge.configuration.gdpr_defaults
          PermissionForge::ResourceField.create!(attrs)
        end
      end

      def build_field_attrs(column_name)
        {
          resource: @resource,
          name: column_name,
          label: column_name.humanize,
          is_active: true,
          is_editable: true,
          read_access: @grant_all,
          edit_access: @grant_all
        }
      end

      def ignored_fields
        PermissionForge.configuration.ignored_fields
      end

      # Virtual fields get rows only under extra_fields_default_access =
      # :unconfigured. Under :grant ExtraFieldDefaults already gives declared
      # names read + edit, and a generated row (no access unless grant_all)
      # would take that away from callers that rely on it.
      def virtual_field_names(model_class)
        configuration = PermissionForge.configuration
        return [] if configuration.grant_extra_fields_by_default?

        self.class.without_blank_names(model_class, PermissionForge::VirtualFields.new(model_class, configuration).names)
      end

      # Full access (grant_all) records the recommended strategy without
      # masking; otherwise the column becomes readable, masked.
      def gdpr_default_attrs(column_name)
        _pattern, strategy = PermissionForge.configuration.gdpr_field_patterns.find { |regex, _| column_name.match?(regex) }
        return {} unless strategy
        return { mask_strategy: strategy } if @grant_all

        { mask_strategy: strategy, read_access: true, mask_access: true }
      end
    end
  end
end
