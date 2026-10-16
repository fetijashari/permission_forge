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
    #
    # The explanation comes from the entry that decides (EX): each set is
    # credited with what it did to the final entry (FieldProvenance). A
    # subclass's field is composed along its single-table-inheritance chain
    # as ResourceChain composes it (`bases`, FieldChain): the strictest entry
    # decides, and the outcome says which (FieldOutcome#decided_by).
    class EffectiveFields
      FieldOutcome = EffectiveAccess::FieldOutcome

      # What FiltersResponseAttributes does with a column no set mentions
      # (any other strategy hides it).
      UNCONFIGURED_LEVELS = { 'pass_through' => 'read', 'warn' => 'read', 'mask_all' => 'masked' }.freeze

      # @param sources [EffectiveAccess::ResourceSources]
      # @param bases [Array<EffectiveAccess::ResourceSources>] the entries the
      #   user has for the model's STI bases, nearest first (ResourceChain)
      def initialize(sources, configuration:, catalog:, bases: [])
        @sources = sources
        @configuration = configuration
        @catalog = catalog
        @bases = bases
        # entry: { read_access:, edit_access:, mask_access:, mask_strategy:, sources: [[set, level, strategy]],
        #          variant_of:, before: (the flags before muting), mutes: [[set, level]] }
        @entries = {}
      end

      # @return [Array<EffectiveAccess::FieldOutcome>]
      def call
        chain = FieldChain.new(chain_tables)
        model = @catalog.find(@sources.name)
        (chain.names + Array(model&.managed_field_names)).uniq.map do |field|
          composed_outcome(chain, field, model.present? && model.virtual_field?(field))
        end
      end

      # The resource's own field entries, merged and muted as the engine does.
      #
      # @return [Hash{String => Hash}]
      def entries
        return @entries if @merged

        @merged = true
        merge_granting_fields
        apply_muting_fields
        @entries
      end

      private

      # The resource's FieldChain::Table, then each base's along its chain.
      def chain_tables
        [FieldChain::Table.new(@sources, entries, nil)] + @bases.map do |base|
          FieldChain::Table.new(base, self.class.new(base, configuration: @configuration, catalog: @catalog).entries, base.name)
        end
      end

      def composed_outcome(chain, name, virtual)
        attributes = chain.attributes(name, virtual: virtual, editable: @sources.flags[:edit_access].granted?)
        attributes ? FieldOutcome.new(name: name, unconfigured: false, **attributes) : unconfigured_outcome(name, virtual)
      end

      def active_fields(resource)
        resource.resource_fields.select(&:is_active)
      end

      # The engine's variants (FieldVariants): only names the model has.
      def variants_of(name)
        variants.call(name)
      end

      # The engine's own targets (FieldPermissionMerger.targets_of): a
      # resource's rows under their own names, then the derived variants of
      # the names no row of the resource has.
      def merge_granting_fields
        @sources.grants.each do |ps, resource|
          Services::FieldPermissionMerger.targets_of(active_fields(resource), variants).each do |name, field, variant_of|
            merge_into(entry_for(name, variant_of), field, ps)
          end
        end
        implicit_names.each { |name| @entries[name] ||= implicit_entry }
      end

      # An explicit row for the name (variant_of nil) makes the entry a field
      # of its own, whichever set wrote the derived entry first.
      def entry_for(key, variant_of)
        entry = (@entries[key] ||= { sources: [], variant_of: variant_of })
        entry[:variant_of] = nil if variant_of.nil?
        entry
      end

      def variants
        @variants ||= FieldVariants.new(@sources.name, @configuration)
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
        @entries.each_value { |entry| entry[:before] = entry.slice(:read_access, :edit_access, :mask_access) }
        @sources.mutes.each do |ps, resource|
          active_fields(resource).each { |field| apply_muting_field(ps, field) }
          hide_every_field(ps) if resource.read_access
        end
      end

      # A muting set that revokes the resource's read hides every field, as
      # the engine does (PermissionHashBuilder#mute_fields_of_resource). One
      # that revokes its edit caps every field to read: FieldProvenance does that
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
        level = FieldLevel.muting_provenance(field)
        return if level == 'leave'

        entry[:read_access] = false if field.read_access
        entry[:edit_access] = false if field.read_access || field.edit_access
        entry[:mask_access] = true if field.mask_access
        (entry[:mutes] ||= []) << [permission_set, level]
      end

      def unconfigured_outcome(name, virtual)
        FieldOutcome.new(name: name, level: unconfigured_level, mask_strategy: 'full', granted_by: [], grants: [],
                         blocked_by: [], mutes: [], capped: false, unconfigured: true, virtual: virtual, implicit: false,
                         decided_by: nil, unreadable: false)
      end

      def unconfigured_level
        UNCONFIGURED_LEVELS.fetch(@configuration.unconfigured_field_strategy.to_s, 'hidden')
      end
    end
  end
end
