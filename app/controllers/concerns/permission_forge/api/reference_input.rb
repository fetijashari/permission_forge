# frozen_string_literal: true

module PermissionForge
  module Api
    # How a body attribute that refers to another record is read: the
    # reference's id key (`permission_set_group_id`) and its uuid key
    # (`permission_set_group_uuid`) — the two keys an answer carries for it
    # (Serializers::BaseSerializer.reference_keys) — become the id of the
    # record they name, under the id key. Read by
    # BaseController#with_reference_id.
    #
    # - The id key takes what the caller's finder reads (the numeric id, or
    #   the uuid under api_record_identifier = :uuid).
    # - The uuid key takes the uuid under either setting.
    # - A blank value (null, "") is no reference (nil).
    # - A value that names no record of the scope is a 422 keyed by the key
    #   it was sent in.
    # - Both keys sent, naming different records: on an update, the one that
    #   changes the stored reference wins — the other was sent back as the
    #   answer carried it (a client that edits one key of a whole answer);
    #   a 422 keyed by the uuid key when both change it, or on a create.
    #
    # @api private
    class ReferenceInput
      # The references a body takes, by association, with the message of a
      # value that names no record (under either key).
      REFERENCES = {
        permission_set_group: 'permission_forge.validations.permission_set.group_missing'
      }.freeze

      # What the uuid key is looked up by: text without a NUL byte (PostgreSQL raises on one).
      UUID_TEXT = /\A[^\0]+\z/

      # @return [ActiveRecord::Relation, Class] where the record is looked up
      attr_reader :scope

      # @param key [Symbol] the id key (e.g. :permission_set_group_id)
      # @param scope [ActiveRecord::Relation, Class] where the record is looked up
      # @param record [ActiveRecord::Base, nil] the record an update changes (nil: a create)
      def initialize(key, scope, record: nil)
        @key = key
        @scope = scope
        @record = record if record&.persisted?
        @association = key.to_s.delete_suffix('_id').to_sym
        @uuid_key = Serializers::BaseSerializer.reference_keys(@association).last
      end

      # @param attrs [ActiveSupport::HashWithIndifferentAccess] the section, read by InputShapes
      # @yieldparam value [Object] a value sent under the id key
      # @yieldreturn [ActiveRecord::Base, nil] the record it names
      # @return [ActiveSupport::HashWithIndifferentAccess] attrs, the uuid key folded into the id key
      # @raise [ParamShapes::InvalidParam]
      def call(attrs, &by_id)
        finders = { @key => by_id, @uuid_key => uuid_finder }.select { |param, _| attrs.key?(param) }
        return attrs if finders.empty?

        named = finders.map { |param, finder| id_named(attrs[param], param, finder) }.uniq
        attrs.except(@uuid_key).merge(@key => id_sent(named))
      end

      private

      # Looks a value sent under the uuid key up by uuid.
      def uuid_finder
        ->(value) { scope.find_by(uuid: value) if value.is_a?(String) && UUID_TEXT.match?(value) }
      end

      # The id of the record `value` names, nil for a blank value.
      def id_named(value, param, finder)
        return if value.nil? || value == ''

        finder.call(value)&.id || raise(ParamShapes::InvalidParam.new(param, I18n.t(REFERENCES.fetch(@association))))
      end

      # The one id the keys name (see the class).
      def id_sent(named)
        return named.first if named.size == 1

        changing = @record ? named - [@record.attribute_in_database(@key.to_s)] : named
        return changing.first if changing.size == 1

        raise ParamShapes::InvalidParam.new(@uuid_key, I18n.t('permission_forge.api.errors.reference_conflict', other: @key))
      end
    end
  end
end
