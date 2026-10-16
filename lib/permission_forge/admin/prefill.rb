# frozen_string_literal: true

module PermissionForge
  module Admin
    # What a form shows in a text field: the record's value, except text
    # nobody wrote — a new record's column default (the install migration
    # gave the string columns English defaults: "Untitled Rule", the rule's
    # "You do not have permission to perform this action."; R6 #91), and
    # text the gem generated on a saved record (PermissionForge::GeneratedText:
    # a field or action label equal to the name or its humanized English, a
    # set's, group's or rule's install-default name, the install-default
    # blocked message). Offered as text it would be saved back as the
    # admin's own words in every language (round 7, A#127). What an admin
    # wrote is shown as written.
    #
    # @example
    #   Prefill.text(PermissionSetRule.new, :failure_message)   # => ""
    #   Prefill.text(saved_rule, :failure_message)              # => "Only your own orders."
    #   Prefill.text(field_labelled_owner, :label)              # => "" (the row of owner_id, labelled "Owner" by the gem)
    #
    # @api private
    module Prefill
      # Per attribute: whether a stored value is generated, for the record.
      GENERATED = {
        'label' => ->(record, value) { GeneratedText.label?(value, record.name) },
        'name' => ->(record, value) { GeneratedText.name?(value, record) },
        'failure_message' => ->(_record, value) { GeneratedText.failure_message?(value) }
      }.freeze

      # @param record [ActiveRecord::Base]
      # @param attribute [Symbol, String]
      # @return [String]
      def self.text(record, attribute)
        attribute = attribute.to_s
        value = record.public_send(attribute).to_s
        return '' if record.new_record? && value == record.class.column_defaults[attribute].to_s
        return '' if value.present? && GENERATED[attribute]&.call(record, value)

        value
      end
    end
  end
end
