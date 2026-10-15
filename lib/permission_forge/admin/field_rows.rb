# frozen_string_literal: true

module PermissionForge
  module Admin
    # One row per field on a Resource page: configured ResourceFields, model
    # columns nobody configured yet, and virtual fields — with the flags the
    # UI needs (sensitive, virtual, column missing, level).
    class FieldRows
      # `declared` — a virtual field the model lists in extra_fields_method
      # (a virtual row that is not declared was discovered). `implicit_grant` —
      # no setting in force here (none, or one that is turned off), and
      # ExtraFieldDefaults makes the field readable and editable right now
      # (extra_fields_default_access = :grant).
      Row = Struct.new(:name, :label, :field, :match, :virtual, :missing, :level, :declared, :implicit_grant,
                       keyword_init: true) do
        def configured? = !field.nil?
        def sensitive? = !match.nil?
        def locked? = field && field.is_editable == false
        def active? = field.nil? || field.is_active

        # A setting the engine applies: it exists and is turned on. A row that
        # is configured and not in force is turned off (is_active false); the
        # engine skips it, so the field is treated like one with no setting.
        def in_force? = configured? && active?
      end

      GRANTING_FILTERS = %w[all hidden masked read edit sensitive unconfigured].freeze
      MUTING_FILTERS = %w[all leave mask hide sensitive unconfigured].freeze

      attr_reader :resource, :model

      def initialize(resource, catalog: ModelCatalog.new, sensitive: SensitiveColumns.new)
        @resource = resource
        @muting = resource.permission_set.is_muting
        @model = catalog.find(resource.name)
        @sensitive = sensitive
      end

      def filters
        @muting ? MUTING_FILTERS : GRANTING_FILTERS
      end

      def rows
        @rows ||= (configured_rows + unconfigured_rows).sort_by { |r| [r.configured? ? 0 : 1, r.name] }
      end

      def filtered(filter: 'all', query: nil)
        needle = query.to_s.strip.downcase
        rows.select { |r| match_filter?(r, filter) && (needle.empty? || "#{r.name} #{r.label}".downcase.include?(needle)) }
      end

      def counts
        filters.index_with { |filter| rows.count { |r| match_filter?(r, filter) } }
      end

      def row(name)
        rows.find { |r| r.name == name.to_s }
      end

      # --- sync with model -----------------------------------------------------

      # Managed columns and virtual fields nobody configured in this resource.
      def new_columns
        return [] unless @model

        @model.managed_field_names - configured_names
      end

      def missing_fields
        rows.select(&:missing)
      end

      def ignored_columns
        Array(@model&.ignored_column_names)
      end

      def sync_needed?
        new_columns.any? || missing_fields.any?
      end

      # Whether the sync panel is a warning. A column with no setting in a
      # Muting Permission Set takes nothing away — the normal state, not a
      # gap — so there only a configured field whose column is gone warns.
      def sync_warning?
        missing_fields.any? || (!@muting && new_columns.any?)
      end

      private

      # Every row counts, switched off or not: a field with a row cannot get a
      # second one.
      def configured_names
        @configured_names ||= @resource.resource_fields.map(&:name)
      end

      def configured_rows
        @resource.resource_fields.map { |field| configured_row(field) }
      end

      def configured_row(field)
        name = field.name
        virtual = virtual?(name)
        Row.new(name: name, label: field.label.presence || human(name), field: field, match: @sensitive.match(name),
                virtual: virtual, missing: @model.present? && !virtual && @model.column_names.exclude?(name),
                level: FieldLevel.level_of(field, muting: @muting), declared: declared?(name),
                implicit_grant: !field.is_active && implicit_grant?(name))
      end

      def unconfigured_rows
        new_columns.map do |name|
          Row.new(name: name, label: human(name), field: nil, match: @sensitive.match(name), virtual: virtual?(name),
                  missing: false, level: nil, declared: declared?(name), implicit_grant: implicit_grant?(name))
        end
      end

      def implicit_grant?(name)
        @model.present? && @model.implicit_grant?(name)
      end

      # A field configured while discovery was on stays virtual (not "column
      # missing") after discovery is turned off.
      def virtual?(name)
        @model.present? && @model.virtual_field?(name)
      end

      def declared?(name)
        @model.present? && @model.declared_virtual_field_names.include?(name)
      end

      def human(name)
        @model ? @model.klass.human_attribute_name(name) : name.to_s.humanize
      end

      def match_filter?(row, filter)
        case filter
        when 'all' then true
        when 'sensitive' then row.sensitive?
        when 'unconfigured' then !row.configured?
        else row.level == filter
        end
      end
    end
  end
end
