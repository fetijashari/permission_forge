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
    #   it was sent in; both keys sent must name the same record (an answer
    #   sent back whole names it twice), else a 422 keyed by the uuid key.
    #
    # @api private
    module ReferenceInput
      # The references a body takes, by association, with the message of a
      # value that names no record (under either key).
      REFERENCES = {
        permission_set_group: 'permission_forge.validations.permission_set.group_missing'
      }.freeze

      module_function

      # @param attrs [ActiveSupport::HashWithIndifferentAccess] the section, read by InputShapes
      # @param key [Symbol] the id key (e.g. :permission_set_group_id)
      # @param scope [ActiveRecord::Relation, Class] where the record is looked up
      # @yieldparam value [Object] a value sent under the id key
      # @yieldreturn [ActiveRecord::Base, nil] the record it names
      # @return [ActiveSupport::HashWithIndifferentAccess] attrs, the uuid key folded into the id key
      # @raise [ParamShapes::InvalidParam]
      def call(attrs, key, scope, &by_id)
        association = key.to_s.delete_suffix('_id').to_sym
        uuid_key = Serializers::BaseSerializer.reference_keys(association).last
        finders = { key => by_id, uuid_key => ->(value) { by_uuid(scope, value) } }.select { |param, _| attrs.key?(param) }
        return attrs if finders.empty?

        attrs.except(uuid_key).merge(key => id_sent(attrs, finders, I18n.t(REFERENCES.fetch(association))))
      end

      # The one id the keys sent name, nil for no reference.
      def id_sent(attrs, finders, missing)
        ids = finders.map { |param, finder| id_named(attrs[param], finder) || raise(ParamShapes::InvalidParam.new(param, missing)) }.uniq
        if ids.size > 1
          id_key, uuid_key = finders.keys
          raise ParamShapes::InvalidParam.new(uuid_key, I18n.t('permission_forge.api.errors.reference_conflict', other: id_key))
        end

        ids.first == :none ? nil : ids.first
      end

      # The id of the record `value` names; :none for a blank value (no
      # reference: nil once folded), nil when it names no record.
      def id_named(value, finder)
        return :none if value.nil? || value == ''

        finder.call(value)&.id
      end

      # A uuid is a String without a NUL byte (PostgreSQL raises on one).
      def by_uuid(scope, value)
        scope.find_by(uuid: value) if value.is_a?(String) && !value.empty? && !value.include?("\0")
      end
      private_class_method :id_sent, :id_named, :by_uuid
    end
  end
end
