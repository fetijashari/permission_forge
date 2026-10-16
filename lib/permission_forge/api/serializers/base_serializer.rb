# frozen_string_literal: true

module PermissionForge
  # @api private
  module Api
    module Serializers
      # The JSON API's built-in serializers: `attributes` lists the keys of
      # an answer, in order; each is the serializer's own (private) method
      # of that name, else the record's.
      #
      # A key that refers to another PermissionForge record is declared with
      # {.reference}: the record's numeric id (`permission_set_id`, as
      # through 0.14.1) followed by its uuid (`permission_set_uuid`), so a
      # client that only knows uuids — `api_record_identifier = :uuid`, the
      # identifier the URLs take — can follow it (field test round 8, D#29).
      # Both keys are always there, whatever the identifier setting. A
      # collection looks the uuids up in one query per reference.
      class BaseSerializer
        def initialize(record)
          @record = record
        end

        # @return [Hash{Symbol => Object}] the record's keys, in order
        def as_json(*)
          self.class.attribute_names.to_h do |attr|
            [attr, respond_to?(attr, true) ? send(attr) : @record.public_send(attr)]
          end
        end

        # The uuids of the records the references name, as {.reference_uuids}
        # answers them (a collection passes the lookup of all its records).
        #
        # @param uuids [Hash{Symbol => Hash{Integer => String}}]
        # @return [self]
        def with_reference_uuids(uuids)
          @reference_uuids = uuids
          self
        end

        # @param records [Enumerable<ActiveRecord::Base>]
        # @return [Array<Hash>]
        def self.collection(records)
          records = records.to_a
          uuids = reference_uuids(records)
          records.map { |r| new(r).with_reference_uuids(uuids).as_json }
        end

        def self.attributes(*attrs)
          @attribute_names = attrs
        end

        def self.attribute_names
          @attribute_names || []
        end

        # The two keys of a reference to another PermissionForge record, for
        # `attributes`: `<association>_id` (its numeric id) and
        # `<association>_uuid` (its uuid, read through the association's
        # model; nil when the id is nil or names no record).
        #
        # @param association [Symbol] a belongs_to of the serialized model
        # @return [Array(Symbol, Symbol)]
        def self.reference(association)
          id_key, uuid_key = reference_keys(association)
          own_references << association
          define_method(uuid_key) { reference_uuid(association, id_key) }
          private uuid_key
          [id_key, uuid_key]
        end

        # The one naming of a reference's keys: the id key and the uuid key.
        # The API's input reads the same two names (BaseController#with_reference_id).
        #
        # @param association [Symbol, String]
        # @return [Array(Symbol, Symbol)]
        def self.reference_keys(association)
          [:"#{association}_id", :"#{association}_uuid"]
        end

        # @return [Array<Symbol>] the associations declared with {.reference}, a superclass's too
        def self.references
          inherited = superclass.respond_to?(:references) ? superclass.references : []
          inherited | own_references
        end

        # The uuid of every record the references of `records` name, one
        # query per reference (the referenced model's default scope, the
        # tenant's, applies as it does to the association).
        #
        # @param records [Array<ActiveRecord::Base>]
        # @return [Hash{Symbol => Hash{Integer => String}}] association => { id => uuid }
        def self.reference_uuids(records)
          references.to_h { |association| [association, uuids_named(records, association)] }
        end

        def self.own_references
          @own_references ||= []
        end

        def self.uuids_named(records, association)
          id_key, = reference_keys(association)
          ids = records.filter_map { |record| record.public_send(id_key) }.uniq
          return {} if ids.empty?

          records.first.class.reflect_on_association(association).klass.where(id: ids).pluck(:id, :uuid).to_h
        end
        private_class_method :own_references, :uuids_named

        private

        attr_reader :record

        def reference_uuid(association, id_key)
          @reference_uuids ||= self.class.reference_uuids([record])
          @reference_uuids.fetch(association, {})[record.public_send(id_key)]
        end
      end
    end
  end
end
