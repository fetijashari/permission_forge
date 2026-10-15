module PermissionForge
  module Services
    # Merges the active ResourceField rows of one resource into a fields hash.
    # Extracted from PermissionHashBuilder for SRP, which calls it once per
    # granting set.
    #
    # Rows only: the implicit entries for a model's extra (virtual) fields are
    # added by ExtraFieldDefaults, once per resource, after every set is merged.
    #
    # {.merge_row} is the one definition of merging a row into an entry; the
    # admin's Admin::EffectiveFields explains fields with it.
    #
    # @api private
    class FieldPermissionMerger
      FIELD_PERMISSION_OPTIONS = %i[read_access edit_access].freeze
      FIELD_MASK_OPTIONS = %i[mask_access mask_strategy].freeze
      # The mask of an entry no row that grants read has decided yet.
      DEFAULT_MASK_STRATEGY = 'full'.freeze

      def self.call(...) = new(...).call

      # Merges one row into one entry, across granting sets:
      # - read and edit are OR-ed (any set that grants wins);
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
        FIELD_PERMISSION_OPTIONS.each { |action| entry[action] ||= field.public_send(action) }
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

      # @param variants [FieldVariants] the field variants of the resource's
      #   model (PermissionHashBuilder shares one per resource name)
      def initialize(fields:, resource:, configuration: PermissionForge.configuration,
                     variants: FieldVariants.new(resource.name, configuration))
        @fields = fields
        @resource = resource
        @variants = variants
      end

      def call
        @resource.resource_fields.select(&:is_active).each do |field|
          next unless field.is_active

          @variants.call(field.name).each { |variant| set_field_permissions(variant, field) }
          set_field_permissions(field.name, field)
        end

        @fields
      end

      private

      def set_field_permissions(field_name, field)
        self.class.merge_row(@fields[field_name] ||= {}, field)
      end
    end
  end
end
