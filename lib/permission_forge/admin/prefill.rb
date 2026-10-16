# frozen_string_literal: true

module PermissionForge
  module Admin
    # What a new-record form shows in a text field: the record's value,
    # except the column's own default, which is blank to the admin. The
    # install migration gives the string columns English defaults ("Untitled
    # Rule", the rule's "You do not have permission to perform this
    # action."); offered as text they would be saved as the admin's own
    # words in every language (R6 #91). A saved record shows what it holds.
    #
    # @example
    #   Prefill.text(PermissionSetRule.new, :failure_message)   # => ""
    #   Prefill.text(saved_rule, :failure_message)              # => "Only your own orders."
    #
    # @api private
    module Prefill
      # @param record [ActiveRecord::Base]
      # @param attribute [Symbol, String]
      # @return [String]
      def self.text(record, attribute)
        value = record.public_send(attribute).to_s
        return '' if record.new_record? && value == record.class.column_defaults[attribute.to_s].to_s

        value
      end
    end
  end
end
