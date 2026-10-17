module PermissionForge
  module Services
    # Merges the active ResourceField rows of one resource into a fields hash.
    # Extracted from PermissionHashBuilder for SRP, which calls it once per
    # granting set.
    #
    # Rows only: the implicit entries for a model's extra (virtual) fields are
    # added by ExtraFieldDefaults, once per resource, after every set is merged.
    #
    # {.merge_row} is the one definition of merging a row into an entry;
    # {.targets_of} the one definition of which names a resource's rows write
    # (own names first, then the derived variants of names no row of the
    # resource has). The admin's Admin::EffectiveFields explains fields
    # with both.
    #
    # @api private
    class FieldPermissionMerger
      FIELD_PERMISSION_OPTIONS = %i[read_access edit_access].freeze
      FIELD_MASK_OPTIONS = %i[mask_access mask_strategy].freeze
      # The mask of an entry no row that grants read has decided yet.
      DEFAULT_MASK_STRATEGY = 'full'.freeze

      def self.call(...) = new(...).call

      # Merges one row into one entry, across granting sets:
      # - read is OR-ed (any set that grants wins); edit is OR-ed over the
      #   rows that grant read AND edit — a row with edit alone (written past
      #   ValidatesDependency) grants nothing: a field nobody may read is not
      #   one they may write;
      # - the mask is decided by the rows that GRANT READ alone: AND-ed (any
      #   such set that unmasks wins), with the first such row's strategy.
      #   A row that grants no read (the admin UI's Hidden: read=f, mask=f)
      #   never votes — it used to take part in the AND, so Masked in one set
      #   plus Hidden in another read as plaintext, in either order.
      # The four keys are always present (the hash format is a contract).
      #
      # @param entry [Hash] the field's entry so far, written in place
      # @param field [ResourceField, #read_access] the row
      # @return [Hash] the entry
      def self.merge_row(entry, field)
        # A row that granted read has merged the mask already: read_access is
        # OR-ed, so it is true from that row on and never before.
        decided = entry[:read_access] == true
        read = field.read_access == true
        entry[:read_access] ||= read
        entry[:edit_access] ||= read && field.edit_access == true
        merge_mask(entry, field, decided)
        entry
      end

      def self.merge_mask(entry, field, decided)
        unless field.read_access
          entry[:mask_access] = false unless entry.key?(:mask_access)
          entry[:mask_strategy] ||= DEFAULT_MASK_STRATEGY
          return
        end

        entry[:mask_access] = decided ? entry[:mask_access] && field.mask_access : field.mask_access
        entry[:mask_strategy] = field.mask_strategy unless decided
      end
      private_class_method :merge_mask

      # The names a resource's rows write, in merge order: every row under
      # its own name, then each row's variants (FieldVariants: `owner_id` →
      # `owner_uuid`) for the names no row of the resource has. An explicit
      # row is what the admin wrote: it decides its name alone, whichever row
      # is older; a derived variant only fills a name nothing names. (The
      # derived variants of a row used to merge like granting rows of their
      # names, so an explicit Hidden `owner_uuid` read as the Editable
      # `owner_id` in either order.) Across resources the entries merge as
      # granting rows do: a set with only an `owner_id` row still grants
      # `owner_uuid` through it.
      #
      # @param rows [Array<ResourceField>] the resource's active rows, in id order
      # @param variants [FieldVariants] the variants of the resource's model
      # @return [Array<Array(String, ResourceField, String, nil)>] `[name, row,
      #   variant_of]`: variant_of is the row's name for a derived variant,
      #   nil for a row's own name
      def self.targets_of(rows, variants)
        own = rows.map { |row| [row.name, row, nil] }
        names = own.map(&:first)
        derived = rows.flat_map do |row|
          variants.call(row.name).reject { |variant| names.include?(variant) }.map { |variant| [variant, row, row.name] }
        end
        own + derived
      end

      # @param variants [FieldVariants] the field variants of the resource's
      #   model (PermissionHashBuilder shares one per resource name)
      def initialize(fields:, resource:, configuration: PermissionForge.configuration,
                     variants: FieldVariants.new(resource.name, configuration))
        @fields = fields
        @resource = resource
        @variants = variants
      end

      def call
        rows = @resource.resource_fields.select(&:is_active)
        self.class.targets_of(rows, @variants).each { |name, row, _| set_field_permissions(name, row) }
        @fields
      end

      private

      def set_field_permissions(field_name, field)
        self.class.merge_row(@fields[field_name] ||= {}, field)
      end
    end
  end
end
