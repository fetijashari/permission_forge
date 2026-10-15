# frozen_string_literal: true

module PermissionForge
  # Whether a ResourceField name names something on the Resource's model —
  # what `rake permission_forge:audit` reports (integrity/unknown_fields): a
  # typo such as `emial` configures nothing the model has. Saving does not
  # refuse such a name: FiltersResponseAttributes filters any key of a hash
  # (a key only a serializer computes is configured by a row of its name).
  # A name is a field of the model when it is
  #
  # - a column of its table (a model's `ignored_columns` included), read
  #   again from the database before the name is called unknown: the schema
  #   cache may predate a column a migration just added;
  # - an attribute (`attribute :nickname`) or an `alias_attribute`;
  # - a virtual field: declared (extra_fields_method, also a key only a
  #   serializer computes) or discovered (store accessors, attribute-API
  #   attributes) — PermissionForge::VirtualFields;
  # - a public reader or writer (a store accessor with a custom prefix, a
  #   `delegate … prefix: true`, `has_secure_password`'s `password=`),
  #   as FieldVariants counts one; or
  # - a configured variant (config.field_variant_mappings) of one of those
  #   or of another row of the Resource: `owner_uuid` next to `owner_id`,
  #   the key a serializer computes and FiltersResponseAttributes reads by
  #   its base field (FieldVariants.base_entries).
  #
  # Nothing is said (.for returns nil) when the model cannot be told: the
  # Resource names no Active Record model this app can load (a Resource
  # shared with another app), an abstract class, a table that does not exist
  # (yet), or a database that cannot be asked.
  #
  # @example
  #   names = PermissionForge::FieldNames.for('Customer')
  #   names.include?('email') # => true
  #   names.include?('emial') # => false
  #
  # @api private
  class FieldNames
    # Errors that mean the model cannot be told now.
    UNREADABLE = [NameError, ArgumentError, ActiveRecord::ActiveRecordError].freeze

    # @param resource_name [String, Symbol, nil] the Resource's name
    # @param siblings [Array<String>, #call] the names of the Resource's other
    #   rows (variant bases), or what answers them (asked only when needed)
    # @return [FieldNames, nil] nil when the model cannot be told
    def self.for(resource_name, siblings: [], configuration: PermissionForge.configuration)
      model = resource_name.to_s.safe_constantize
      return unless model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class? && model.table_exists?

      new(model, siblings: siblings, configuration: configuration)
    rescue *UNREADABLE
      nil
    end

    # @return [Class] the Resource's model
    attr_reader :model

    def initialize(model, siblings: [], configuration: PermissionForge.configuration)
      @model = model
      @siblings = siblings
      @configuration = configuration
    end

    # @param name [String, Symbol]
    # @return [Boolean] whether the model has the name (its table read again, once, before saying no)
    def include?(name)
      name = name.to_s
      return true if known?(name)
      return false if @reread

      reread!
      known?(name)
    rescue *UNREADABLE
      true
    end

    private

    # Once per instance: the table's columns as they are now.
    def reread!
      @reread = true
      @model.reset_column_information
      @virtual_fields = nil
    end

    def known?(name)
      own?(name) || variant?(name)
    end

    def own?(name)
      columns.include?(name) || @model.attribute_names.include?(name) || @model.attribute_alias?(name) ||
        virtual_fields.include?(name) || @model.public_method_defined?(name) ||
        @model.public_method_defined?("#{name}=")
    end

    def variant?(name)
      (columns + @model.attribute_names + virtual_fields.names + siblings).uniq.any? do |base|
        base != name && @configuration.field_variants_for(base).include?(name)
      end
    end

    def siblings
      @siblings = Array(@siblings.respond_to?(:call) ? @siblings.call : @siblings).map(&:to_s)
    end

    # The table's columns as the database has them: ignored_columns too.
    def columns
      @model.connection.schema_cache.columns_hash(@model.table_name).keys
    end

    def virtual_fields
      @virtual_fields ||= VirtualFields.new(@model, @configuration)
    end
  end
end
