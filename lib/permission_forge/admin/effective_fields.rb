# frozen_string_literal: true

module PermissionForge
  module Admin
    # Field half of EffectiveAccess for one resource: mirrors what
    # PermissionHashBuilder does with fields (FieldPermissionMerger's ||=
    # read/edit, AND-merged mask and variants, then extra fields, then muting)
    # while keeping which sets granted or muted each field.
    #
    # Extra fields follow the engine: after every granting set is merged, each
    # declared name that nothing configured gets the implicit entry
    # (ExtraFieldDefaults). A row in any set wins, whatever the set order.
    class EffectiveFields
      FieldOutcome = EffectiveAccess::FieldOutcome
      FieldSource = EffectiveAccess::FieldSource

      # What FiltersResponseAttributes does with a column no set mentions
      # (any other strategy hides it).
      UNCONFIGURED_LEVELS = { 'pass_through' => 'read', 'warn' => 'read', 'mask_all' => 'masked' }.freeze

      # @param sources [EffectiveAccess::ResourceSources]
      def initialize(sources, configuration:, catalog:)
        @sources = sources
        @configuration = configuration
        @catalog = catalog
        # entry: { read_access:, edit_access:, mask_access:, mask_strategy:, sources: [[set, level]], variant_of: }
        @entries = {}
      end

      # @return [Array<EffectiveAccess::FieldOutcome>]
      def call
        merge_granting_fields
        apply_muting_fields

        model = @catalog.find(@sources.name)
        (@entries.keys + Array(model&.managed_field_names)).uniq.map do |field|
          field_outcome(field, model.present? && model.virtual_field?(field))
        end
      end

      private

      def active_fields(resource)
        resource.resource_fields.select(&:is_active)
      end

      # The engine's variants (FieldVariants): only names the model has.
      def variants_of(name)
        (@variants ||= FieldVariants.new(@sources.name, @configuration)).call(name)
      end

      def merge_granting_fields
        @sources.grants.each do |ps, resource|
          active_fields(resource).each { |field| merge_granting_field(ps, field) }
        end
        implicit_names.each { |name| @entries[name] ||= implicit_entry }
      end

      def merge_granting_field(permission_set, field)
        name = field.name
        variants_of(name).each { |variant| merge_into(entry_for(variant, name), field, permission_set) }
        merge_into(entry_for(name, nil), field, permission_set)
      end

      def entry_for(key, variant_of)
        @entries[key] ||= { sources: [], variant_of: variant_of }
      end

      # The engine's own merge (FieldPermissionMerger.merge_row), plus provenance.
      def merge_into(entry, field, permission_set)
        Services::FieldPermissionMerger.merge_row(entry, field)
        entry[:sources] << [permission_set, FieldLevel.level_of(field, muting: false), field.mask_strategy]
      end

      # Declared names that get the implicit read + edit entry; none under
      # extra_fields_default_access = :unconfigured (they are then listed as
      # unconfigured virtual fields instead). Read for any constant, like the
      # engine does, not only for the models the catalog lists.
      def implicit_names
        PermissionForge::VirtualFields.new(@sources.name.to_s.safe_constantize, @configuration).implicit
      end

      # The engine's entry for the resource flags as the granting sets merged
      # them (what some granting set grants, blocked later or not).
      def implicit_entry
        granted = @sources.flags.transform_values { |outcome| !outcome.granted_by.empty? }
        Services::ExtraFieldDefaults.implicit_entry(granted).merge(sources: [], extra: true)
      end

      def apply_muting_fields
        @sources.mutes.each do |ps, resource|
          active_fields(resource).each { |field| apply_muting_field(ps, field) }
          hide_every_field(ps) if resource.read_access
        end
      end

      # A muting set that revokes the resource's read hides every field, as
      # the engine does (PermissionHashBuilder#mute_fields_of_resource). One
      # that revokes its edit caps every field to read: level_attrs does that
      # from the resource's edit outcome.
      def hide_every_field(permission_set)
        @entries.each_value { |entry| hide_entry(entry, permission_set) }
      end

      def hide_entry(entry, permission_set)
        entry[:read_access] = false
        entry[:edit_access] = false
        (entry[:mutes] ||= []) << [permission_set, 'hide']
      end

      def apply_muting_field(permission_set, field)
        name = field.name
        ([name] + variants_of(name)).each do |key|
          entry = @entries[key]
          mute_field(entry, field, permission_set) if entry
        end
      end

      # The engine's own muting of a row (PermissionHashBuilder
      # #mute_single_field: a row that mutes read mutes edit too), plus
      # provenance.
      def mute_field(entry, field, permission_set)
        level = FieldLevel.level_of(field, muting: true)
        return if level == 'leave'

        entry[:read_access] = false if field.read_access
        entry[:edit_access] = false if field.read_access || field.edit_access
        entry[:mask_access] = true if field.mask_access
        (entry[:mutes] ||= []) << [permission_set, level]
      end

      def field_outcome(name, virtual)
        entry = @entries[name]
        return unconfigured_outcome(name, virtual) if entry.nil?

        implicit = entry[:extra].present?
        grants = granting_sources(entry)
        FieldOutcome.new(
          name: name, mask_strategy: entry[:mask_strategy], granted_by: grants.map(&:permission_set), grants: grants,
          unconfigured: false, virtual: virtual || implicit, implicit: implicit, variant_of: entry[:variant_of],
          **level_attrs(entry), **muting_attrs(entry)
        )
      end

      # Editable fields are capped to Read when the resource's Edit is not granted.
      def level_attrs(entry)
        level = FieldLevel.effective_level(entry)
        capped = level == 'edit' && !@sources.flags[:edit_access].granted?
        { level: capped ? 'read' : level, capped: capped }
      end

      # One FieldSource per muting set; a set that both masks and hides the
      # field (its own row, and Read muted on the resource) hides it.
      def muting_attrs(entry)
        sources = muting_sources(entry)
        { blocked_by: sources.map(&:permission_set), blocked_level: entry[:mutes]&.last&.last, mutes: sources }
      end

      def muting_sources(entry)
        (entry[:mutes] || []).group_by(&:first).map { |ps, rows| muting_source(ps, rows.map(&:last)) }
      end

      def muting_source(permission_set, levels)
        FieldSource.new(permission_set: permission_set, level: levels.include?('hide') ? 'hide' : 'mask')
      end

      # The sets that make the field readable, one FieldSource each at its
      # most open level, most open first. A set that lists the field as
      # Hidden grants nothing and, like the engine, has no say in the mask.
      # An implicit entry exists only when no set configured the field, so no
      # set is credited for it: the level comes from the virtual-field default.
      def granting_sources(entry)
        return [] if entry[:extra]

        entry[:sources].select { |_, lvl, _| FieldLevel.rank(lvl) >= 1 }
                       .sort_by { |_, lvl, _| -FieldLevel.rank(lvl) }.uniq(&:first)
                       .map { |ps, lvl, strategy| FieldSource.new(permission_set: ps, level: lvl, mask_strategy: strategy) }
      end

      def unconfigured_outcome(name, virtual)
        FieldOutcome.new(name: name, level: unconfigured_level, mask_strategy: 'full', granted_by: [], grants: [],
                         blocked_by: [], mutes: [], capped: false, unconfigured: true, virtual: virtual, implicit: false)
      end

      def unconfigured_level
        UNCONFIGURED_LEVELS.fetch(@configuration.unconfigured_field_strategy.to_s, 'hidden')
      end
    end
  end
end
