# frozen_string_literal: true

module PermissionForge
  # The one definition of the fields a model's Resource has rows for: its
  # columns (`ignored_columns` and config.ignored_fields left out), then its
  # virtual fields (PermissionForge::VirtualFields: declared and
  # discovered), whatever extra_fields_default_access says. Every path that
  # creates rows for a model writes rows for these names and no others —
  # the admin's presets, "Sync fields" and bulk add (a posted name outside
  # them is no row), and ResourceFieldGenerator — so a level chosen for "all
  # fields" (Hidden, say) reaches a virtual field on every path. The admin's
  # model catalog lists them (Admin::ModelCatalog::ModelInfo#managed_field_names).
  #
  # The columns are read through PermissionForge::SchemaRead: compared with
  # the database first with `verify: true` (a list that builds rows), from
  # the schema cache without it (a count on every admin page).
  #
  # @api private
  class ManagedFields
    # @param model [Class] an Active Record model with a table
    # @param configuration [Configuration]
    # @param verify [Boolean] compare the columns with the database first
    def initialize(model, configuration: PermissionForge.configuration, verify: true)
      @model = model
      @configuration = configuration
      @verify = verify
    end

    # @return [Array<String>] the model's columns (`ignored_columns` excluded)
    def column_names
      @column_names ||= SchemaRead.column_names(@model, verify: @verify)
    end

    # @return [Array<String>] the columns config.ignored_fields leaves out
    def ignored_column_names
      column_names & ignored_fields
    end

    # @return [Array<String>] the columns that get rows
    def managed_column_names
      column_names - ignored_fields
    end

    # @return [Array<String>] declared and discovered virtual fields
    def virtual_field_names
      virtual_fields.names
    end

    # @return [Array<String>] managed columns, then virtual fields
    def names
      managed_column_names + virtual_field_names
    end

    # @return [VirtualFields]
    def virtual_fields
      @virtual_fields ||= VirtualFields.new(@model, @configuration)
    end

    private

    # Symbols or Strings, as the host wrote them.
    def ignored_fields
      @ignored_fields ||= Array(@configuration.ignored_fields).map(&:to_s)
    end
  end
end
