module PermissionForge
  module Concerns
    # Refuses nil for every column the schema declares NOT NULL as a
    # validation error keyed by the attribute, so a JSON `null` or a blank
    # form value (a boolean column casts "" to nil) is a 422 in the API and
    # the form again in the admin, where the database raised NotNullViolation
    # (a 500). Read from the schema: a NOT NULL column added later is covered
    # without a change here.
    #
    # Left to whoever fills them: the primary key; on a new record the
    # columns Rails or the gem fill when the row is created (the timestamps,
    # `uuid` from HasUuid); a column that already has an error once every
    # other validation ran — a presence rule's, with or without a condition
    # — or whose required `belongs_to` names it as the foreign key (one
    # message, not two). The check runs after every other validation of the
    # model whatever the order they were declared in: an `:after` callback
    # of the `validate` chain (canary `:validate_after_callback`).
    #
    # @api private
    module ValidatesRequiredColumns
      extend ActiveSupport::Concern

      # Filled by the gem when a row is created (HasUuid, before_create).
      FILLED_ON_CREATE = %w[uuid].freeze
      # Filled by Rails when a row is created while record_timestamps is on.
      TIMESTAMPS = %w[created_at created_on updated_at updated_on].freeze

      included do
        # After every `validate` / `validates` of the model, also those
        # declared below the include or in a subclass.
        set_callback :validate, :after, :validate_required_columns
      end

      # Whether `association` is a required belongs_to: Rails' own presence
      # rule (message :required), whose condition holds whenever the
      # foreign key is nil.
      def self.required_association?(klass, association)
        klass.validators_on(association).any? { |validator| validator.kind == :presence && validator.options[:message] == :required }
      end

      private

      def validate_required_columns
        self.class.columns.each do |column|
          name = column.name
          next if column.null || !has_attribute?(name) || !read_attribute(name).nil? || filled_elsewhere?(name)

          errors.add(name, :blank, message: ->(*) { I18n.t('permission_forge.validations.blank') })
        end
      end

      # Said already (an error on the attribute), or filled or checked by someone else.
      def filled_elsewhere?(name)
        klass = self.class
        return true if errors.include?(name) || name == klass.primary_key
        return true if new_record? && filled_on_create?(name)

        required_foreign_key?(name)
      end

      def filled_on_create?(name)
        FILLED_ON_CREATE.include?(name) || (self.class.record_timestamps && TIMESTAMPS.include?(name))
      end

      # The foreign key of a required belongs_to: its error is keyed by the association.
      def required_foreign_key?(name)
        klass = self.class
        klass.reflect_on_all_associations(:belongs_to).any? do |reflection|
          reflection.foreign_key.to_s == name && ValidatesRequiredColumns.required_association?(klass, reflection.name)
        end
      end
    end
  end
end
