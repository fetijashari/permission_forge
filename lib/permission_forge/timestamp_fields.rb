# frozen_string_literal: true

module PermissionForge
  # Rails' own timestamps (created_at / updated_at, created_on / updated_on)
  # in the field rows the gem generates: ResourceFieldGenerator (also
  # Resource.grant_full_access! and the API's generate_fields) and the
  # admin's presets and "Sync fields" (Admin::ColumnFields).
  #
  # They are metadata a reader of the record may see and nobody edits, so on
  # a granting Permission Set a generated timestamp row is at most Read-only:
  # a level that grants read (Masked, Read-only, Editable) gives it read on,
  # edit off and no mask; a level that grants nothing (Hidden, "No access",
  # the generator without grant_all) leaves it hidden like every other column
  # (a granting row adds access, so a readable timestamp there would widen
  # what the set's holders see). On a Muting Permission Set read on means
  # "take read away": its rows are left as the level says.
  #
  # Rows written one by one (the admin's field editor, the API, the console)
  # are not changed.
  #
  # @api private
  class TimestampFields
    # Rails' default names (ActiveRecord::Timestamp); only those the model has
    # as columns count.
    NAMES = %w[created_at created_on updated_at updated_on].freeze

    READ_ONLY = { read_access: true, edit_access: false, mask_access: false }.freeze

    # @param model_class [Class, nil]
    # @return [Array<String>] the timestamp columns of the model
    def self.names(model_class)
      return [] unless model_class.respond_to?(:column_names)

      NAMES & model_class.column_names
    rescue ActiveRecord::ActiveRecordError # no table: the rows take the level as chosen
      []
    end

    # @param model_class [Class, nil] the Resource's model
    # @param muting [Boolean] the rows are a Muting Permission Set's
    def initialize(model_class, muting:)
      @names = muting ? [] : self.class.names(model_class)
    end

    # What a generated row of `name` gets over the flags of its level.
    #
    # @param name [String] the field name
    # @param read [Boolean] the level gives the row read_access
    # @return [Hash] Read-only for a readable timestamp of a granting set, else nothing
    def overrides(name, read:)
      read && @names.include?(name.to_s) ? READ_ONLY : {}
    end
  end
end
