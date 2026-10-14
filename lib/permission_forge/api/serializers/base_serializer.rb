# frozen_string_literal: true

module PermissionForge
  # @api private
  module Api
    module Serializers
      class BaseSerializer
        def initialize(record)
          @record = record
        end

        def as_json(*)
          self.class.attribute_names.to_h do |attr|
            [attr, respond_to?(attr, true) ? send(attr) : @record.public_send(attr)]
          end
        end

        def self.collection(records)
          records.map { |r| new(r).as_json }
        end

        def self.attributes(*attrs)
          @attribute_names = attrs
        end

        def self.attribute_names
          @attribute_names || []
        end

        private

        attr_reader :record
      end
    end
  end
end
