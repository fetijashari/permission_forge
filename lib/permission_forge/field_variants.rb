# frozen_string_literal: true

module PermissionForge
  # The names a field row's setting also applies to on one Resource:
  # Configuration#field_variants_for (config.field_variant_mappings:
  # `owner_id` → `owner_uuid`, `price_cents` → `price`), kept to the names
  # the Resource's model has —
  #
  # - an attribute (a column, or one declared with `attribute`),
  # - an `alias_attribute`,
  # - a public reader or writer (a `delegate :uuid, to: :owner, prefix: true`
  #   defines `owner_uuid`; `def owner_uuid=(uuid)` takes one), or
  # - a declared virtual field (PermissionForge::VirtualFields#extra).
  #
  # A name the model does not have would be an entry in the permission hash
  # for nothing (the admin's Effective access listed it as a field and
  # counted it). A model that cannot be read — no such constant (a Resource
  # shared with another app), not an Active Record model, a schema that
  # cannot be loaded — keeps every variant, as before 0.15.
  #
  # A hash a serializer builds can still carry such a name (`owner_uuid`
  # computed in a view): FiltersResponseAttributes reads it by the entry of
  # the field it is a variant of (.base_entries), as when the hash had it.
  #
  # The one definition for the permission hash (granting and muting,
  # PermissionHashBuilder / FieldPermissionMerger) and the admin
  # (Admin::EffectiveFields, Admin::FieldDetail), which must agree.
  #
  # @example
  #   variants = PermissionForge::FieldVariants.new('Customer')
  #   variants.call('supplier_id') # => [] (Customer has no supplier_uuid)
  #
  # @api private
  class FieldVariants
    # Errors that mean the model's attributes cannot be read (no connection,
    # a schema that cannot be loaded).
    UNREADABLE = [ActiveRecord::ActiveRecordError].freeze

    # The entries of the configured fields by the names of their variants
    # (`owner_uuid` → the `owner_id` entry), to read a name that has no entry
    # of its own. A name two fields map to (custom field_variant_mappings)
    # gets the strictest of their entries (ResourceChain.strictest, the one
    # definition): such a key is never more readable than any of its bases.
    # This covers names the model does
    # not have (serializer keys); a variant the model has gets its entry from
    # FieldPermissionMerger, which merges every base row like any granting row.
    #
    # @param fields [Hash] a resource's field entries, by name
    # @return [Hash{String => Hash}]
    def self.base_entries(fields, configuration = PermissionForge.configuration)
      bases = fields.each_with_object({}) do |(base, entry), by_variant|
        configuration.field_variants_for(base).each { |variant| (by_variant[variant] ||= []) << entry }
      end
      bases.transform_values { |entries| ResourceChain.strictest(entries) }
    end

    # @param resource_name [String, Symbol] the Resource's name (a model's class name)
    # @param configuration [Configuration]
    def initialize(resource_name, configuration = PermissionForge.configuration)
      @resource_name = resource_name.to_s
      @configuration = configuration
      @variants = {}
    end

    # @param field_name [String, Symbol]
    # @return [Array<String>] the variants of the field that the model has
    def call(field_name)
      @variants[field_name.to_s] ||= @configuration.field_variants_for(field_name).select { |name| attribute?(name) }
    end

    private

    def attribute?(name)
      return true unless model

      model.attribute_names.include?(name) || model.attribute_alias?(name) || model.public_method_defined?(name) ||
        model.public_method_defined?("#{name}=") || virtual_names.include?(name)
    rescue *UNREADABLE
      true
    end

    def model
      return @model if defined?(@model)

      klass = @resource_name.safe_constantize
      @model = klass.is_a?(Class) && klass < ActiveRecord::Base ? klass : nil
    end

    def virtual_names
      @virtual_names ||= VirtualFields.new(model, @configuration).extra
    end
  end
end
