module PermissionForge
  module Concerns
    # Refuses a string the database cannot hold as a validation error, so the
    # admin and the API answer 422 where a strict MySQL raised ValueTooLong
    # (a 500). The limit is the column's own, read from the schema: a
    # `string` column's in characters, a `text` column's in bytes (MySQL
    # TEXT holds 65,535 of them). A column that declares no limit (a
    # PostgreSQL or SQLite `string`) is not checked, and an attribute with a
    # length rule of its own at most as long as the column (PermissionSet#name)
    # keeps that rule alone.
    #
    # Only attributes being written are checked: a longer value stored
    # before (on a database that held it) leaves the row's other attributes
    # editable.
    #
    # @api private
    module ValidatesColumnLengths
      extend ActiveSupport::Concern

      # How each column type measures its limit.
      MEASURES = {
        string: :length,
        text: :bytesize
      }.freeze

      included do
        validate :validate_column_lengths
      end

      # The longest value a validator lets through; any other validator
      # lets through anything.
      def self.maximum_of(validator)
        return Float::INFINITY unless validator.is_a?(ActiveModel::Validations::LengthValidator)

        options = validator.options
        options[:maximum] || options[:in]&.max || Float::INFINITY
      end

      private

      def validate_column_lengths
        self.class.columns.each do |column|
          name = column.name
          next unless column.limit && will_save_change_to_attribute?(name)

          check_column_length(name, column)
        end
      end

      def check_column_length(name, column)
        measure = MEASURES[column.type]
        value = read_attribute(name)
        return unless measure && value.is_a?(String) && value.public_send(measure) > column.limit

        limit = column.limit
        return if stricter_length_rule?(name, limit)

        errors.add(name, :too_long, count: limit,
                                    message: ->(*) { I18n.t('permission_forge.validations.too_long', count: limit) })
      end

      # The attribute's own length rule already refuses everything the column
      # cannot hold (its maximum is the column's or less): its message alone.
      def stricter_length_rule?(name, limit)
        self.class.validators_on(name).any? { |validator| ValidatesColumnLengths.maximum_of(validator) <= limit }
      end
    end
  end
end
