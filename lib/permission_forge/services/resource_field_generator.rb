require_relative 'resource_field_generator/row_builder'

module PermissionForge
  module Services
    # Creates a ResourceField for every column of a resource's model (and declared virtual fields
    # under `extra_fields_default_access = :unconfigured`).
    #
    # @api public
    class ResourceFieldGenerator
      # Every generated row is built by {RowBuilder}, the one definition the
      # admin's presets, "Sync fields" and the Fields tab's bulk add share.
      # With `grant_all` the caller asked for full access (Editable): every
      # field readable and editable, unmasked — also the columns that look
      # like personal data, which keep the recommended mask strategy for
      # when someone masks them and are still reported as personal data
      # (GdprFieldAuditor, the admin's privacy audit). Without it every
      # field is Hidden; under `gdpr_defaults` the privacy default masks what
      # is granted Read, and nothing is granted here. On a Muting Permission
      # Set `grant_all` takes everything away (Hide); without it nothing is
      # written — Unchanged is no row (FieldLevel.row?), as in the admin.
      # Rails' timestamps
      # (created_at / updated_at) are at most read-only on a granting set
      # (PermissionForge::TimestampFields).
      #
      # @param resource [Resource]
      # @param grant_all [Boolean] grant read and edit, unmasked, on the generated fields
      # @return [Array<ResourceField>] the fields created
      def self.call(resource:, grant_all: false)
        new(resource: resource, grant_all: grant_all).call
      end

      # The attributes of one generated row — the one definition every path
      # that creates rows for a model's columns uses ({RowBuilder#attrs}).
      #
      # @param resource [Resource] its Permission Set says whether the row is a muting one
      # @param column [String, Symbol] a column or virtual field name
      # @param level [String] a FieldLevel of the set's kind
      # @return [Hash, nil] the row's attributes, nil for a blank name
      def self.build(resource:, column:, level:)
        rows(resource).attrs(column, level)
      end

      # A builder for several rows of one Resource (the model and the matcher
      # are resolved once). Keywords as {RowBuilder#initialize}: `muting:`
      # (default: the Resource's set says), `configuration:`, `sensitive:`.
      #
      # @param resource [Resource]
      # @return [RowBuilder]
      def self.rows(resource, **)
        RowBuilder.new(resource, **)
      end

      def initialize(resource:, grant_all: false)
        @resource = resource
        @grant_all = grant_all
      end

      # All or nothing, under one audit correlation id (an enclosing block's,
      # if any): a field that cannot be saved leaves no field and no event.
      # A Resource named after no model this app can load
      # (PermissionForge::ModelLookup: `Custmer`, `Kernel`, a model without
      # its table) has no columns: no fields, a log line — never an error
      # (the API answers 422 before it gets here; `rake permission_forge:audit`
      # lists the Resource under unknown_models).
      def call
        model_class = PermissionForge::ModelLookup.model_for(@resource.name)
        return no_model unless model_class

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

      def no_model
        Rails.logger&.warn("[PermissionForge] #{@resource.name} names no model this app can load: no fields generated")
        []
      end

      def generate_fields(model_class)
        existing_names = @resource.resource_fields.pluck(:name)
        columns = PermissionForge::SchemaRead.column_names(model_class, verify: true) - ignored_fields +
                  virtual_field_names(model_class) - existing_names

        rows = RowBuilder.new(@resource, muting: muting?)
        columns.filter_map do |column_name|
          attrs = rows.attrs(column_name, level)
          PermissionForge::ResourceField.create!(attrs.merge(resource: @resource)) if attrs
        end
      end

      def muting?
        @resource.permission_set&.is_muting || false
      end

      # The level generated rows get: full access or none; on a Muting
      # Permission Set the level that takes everything away, or Unchanged,
      # which the row builder writes no row for.
      def level
        if muting?
          @grant_all ? 'hide' : 'leave'
        else
          @grant_all ? 'edit' : 'hidden'
        end
      end

      # Symbols or Strings, as the host wrote them.
      def ignored_fields
        Array(PermissionForge.configuration.ignored_fields).map(&:to_s)
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
    end
  end
end
