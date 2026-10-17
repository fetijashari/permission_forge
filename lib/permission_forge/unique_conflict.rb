# frozen_string_literal: true

module PermissionForge
  # The validation error a uniqueness race would have shown.
  #
  # Four models validate uniqueness with a unique index behind the validation
  # (a Resource or a field name per set or resource, one assignment or
  # membership per person): two requests that pass the validation together
  # leave the second INSERT to the index, which raises
  # ActiveRecord::RecordNotUnique. The admin and the API answer it the way
  # they answer the validation — a 422 keyed by the attribute, the form's
  # page with the message — from the index the error names. The adapters
  # word the error differently (SQLite names the columns, PostgreSQL and
  # MySQL the index), so the index name and every `table.column` of the
  # index are looked for, and nothing else of the message is parsed.
  #
  # @api private
  module UniqueConflict
    # A uniqueness validation (its attribute and validator) of a model.
    Conflict = Data.define(:model, :attribute, :validator) do
      # The validation's own errors, as `record.errors` would hold them:
      # `:taken` with the validator's `message:` option, as the validator
      # adds it.
      #
      # @return [ActiveModel::Errors]
      def errors
        list = model.new.errors
        list.add(attribute, :taken, **validator.options.slice(:message))
        list
      end
    end

    class << self
      # `{ user_id: ["has already been taken"] }`: the validation's message
      # for the unique index `error` names, keyed by the attribute like
      # `record.errors.messages`; nil when the index belongs to no
      # uniqueness validation of the models (a uuid index, a host's own
      # index, a message naming nothing).
      #
      # @param error [ActiveRecord::RecordNotUnique]
      # @return [Hash{Symbol => Array<String>}, nil]
      def messages(error)
        find(error)&.errors&.messages
      end

      # The same as one sentence in the current locale ("Name already exists
      # in this permission set", Admin::ErrorSentence); nil as for .messages.
      #
      # @param error [ActiveRecord::RecordNotUnique]
      # @return [String, nil]
      def sentence(error)
        conflict = find(error)
        conflict && Admin::ErrorSentence.first(conflict.errors)
      end

      # The uniqueness validation behind the unique index `error` names.
      #
      # @param error [ActiveRecord::RecordNotUnique]
      # @return [Conflict, nil]
      def find(error)
        text = error.message.to_s
        models.each do |model|
          index = unique_indexes(model).find { |candidate| names?(text, candidate, model.table_name) }
          return conflict_for(model, index) if index
        end
        nil
      end

      # The uniqueness validator of `model` whose attribute and scope are
      # exactly the columns of `index`, with that attribute.
      #
      # @param model [Class] one of the models
      # @param index [ActiveRecord::ConnectionAdapters::IndexDefinition]
      # @return [Conflict, nil]
      def conflict_for(model, index)
        columns = Array(index.columns).map(&:to_s).sort
        model.validators.each do |validator|
          attribute = validated_attribute(validator, columns)
          return Conflict.new(model: model, attribute: attribute, validator: validator) if attribute
        end
        nil
      end

      private

      # The attribute of a uniqueness validator that, with the validator's
      # scope, is exactly `columns` (sorted); nil for any other validator.
      def validated_attribute(validator, columns)
        return unless validator.kind == :uniqueness

        scope = Array(validator.options[:scope]).map(&:to_s)
        validator.attributes.find { |name| ([name.to_s] + scope).sort == columns }
      end

      def models
        PermissionForge::MODEL_NAMES.map { |name| PermissionForge.const_get(name) }
      end

      # The unique indexes of the model's table; none when the table cannot
      # be read (no table yet, no database): nothing is named then.
      def unique_indexes(model)
        model.connection_pool.with_connection { |connection| connection.indexes(model.table_name) }.select(&:unique)
      rescue ActiveRecord::ActiveRecordError
        []
      end

      # Whether the adapter's message names the index: by its name
      # (PostgreSQL, MySQL) or by each of its columns as table.column (SQLite).
      def names?(text, index, table)
        return true if index.name.present? && text.match?(/\b#{Regexp.escape(index.name.to_s)}\b/)

        columns = Array(index.columns).map(&:to_s)
        columns.any? && columns.all? { |column| text.include?("#{table}.#{column}") }
      end
    end
  end
end
