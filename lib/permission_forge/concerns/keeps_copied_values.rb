# frozen_string_literal: true

module PermissionForge
  module Concerns
    # A copy (Services::Clonable: `record.dup`) names what its original names.
    # The checks a row gets when it is new or when an attribute changes —
    # an operator or join type this version knows, a mask strategy that is
    # one, an IP list of addresses — would refuse a copy of a row stored
    # before them (or written past the model), and with it the whole copy
    # of the set: a 500 in the admin's Duplicate. The copy keeps its
    # original's stored values instead and behaves exactly like it (the rule
    # matches nothing, the field masks fully, the condition never passes);
    # `rake permission_forge:audit` reports both rows.
    #
    #   keeps_copied :operator, :join_type
    #   validates :operator, ..., if: -> { !copied_unchanged?(:operator) && (new_record? || ...) }
    #
    # @api private
    module KeepsCopiedValues
      extend ActiveSupport::Concern

      included do
        class_attribute :pf_copied_attributes, instance_writer: false, default: [].freeze
      end

      class_methods do
        # @param attributes [Array<Symbol>] the attributes a copy keeps unchecked while it holds the original's value
        # @return [void]
        def keeps_copied(*attributes)
          self.pf_copied_attributes = (pf_copied_attributes + attributes.map(&:to_s)).uniq.freeze
        end
      end

      def initialize_dup(other)
        super
        @pf_copied = attributes.slice(*pf_copied_attributes).freeze
      end

      private

      # Whether this row is a copy and each attribute still holds what the
      # original held: a check-on-change validation is not due for it.
      def copied_unchanged?(*names)
        !@pf_copied.nil? && names.all? { |name| @pf_copied.key?(name.to_s) && @pf_copied[name.to_s] == self[name] }
      end
    end
  end
end
