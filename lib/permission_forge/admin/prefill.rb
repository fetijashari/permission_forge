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
    # The save side is {.posted}, the one definition every admin form's save
    # asks (the field drawer, the action form, the set page, the rule
    # builder, the group page): a blank posted over stored generated text is
    # the form's own blank pre-fill sent back — no change; the stored value
    # stays and no change or audit event is recorded. Anything else posted
    # is the admin's: typed text renames, and a blank over text an admin
    # wrote is handled by each form as before (a field label is stored as
    # the name; a set's, rule's or group's name is required).
    #
    # @example
    #   Prefill.text(PermissionSetRule.new, :failure_message)   # => ""
    #   Prefill.text(saved_rule, :failure_message)              # => "Only your own orders."
    #   Prefill.text(field_labelled_owner, :label)              # => "" (the row of owner_id, labelled "Owner" by the gem)
    #   Prefill.posted(field_labelled_owner, :label, '')        # => "Owner" (unchanged)
    #   Prefill.posted(field_labelled_owner, :label, 'Seller')  # => "Seller"
    #
    # @api private
    module Prefill
      # Per attribute: whether a stored value is generated, for the record.
      # The text attributes .posted keeps under a blank.
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

      # The value a form's save takes for `attribute`: `value` as posted —
      # except a blank one over stored generated text (see {GENERATED}),
      # which is the blank the form pre-filled ({.text}), and a blank one
      # over nothing stored (an empty text field sends "" for a NULL): the
      # stored value, so the save sees no change. A new record has nothing
      # stored.
      #
      # @param record [ActiveRecord::Base, nil] the record being saved (nil: a new one)
      # @param attribute [Symbol, String]
      # @param value [Object] the posted value
      # @return [Object] the stored value, or `value`
      def self.posted(record, attribute, value)
        attribute = attribute.to_s
        return value unless (value.nil? || (value.is_a?(String) && value.strip.empty?)) && record&.persisted?

        stored = record.attribute_in_database(attribute)
        return stored if stored.blank? && !stored.equal?(false)

        GENERATED[attribute]&.call(record, stored.to_s) ? stored : value
      end
    end
  end
end
