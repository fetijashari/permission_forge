# frozen_string_literal: true

module PermissionForge
  module Concerns
    # The one definition of what a blank label is stored as, for every model
    # with a `label` column: a field row, an action row and a Resource. A
    # label that is nil, empty or only whitespace is "no label", and so is
    # the install migration's column default on a new row ('Untitled Field');
    # such a label is stored as #generated_label — on create and on update,
    # in code, through the JSON API and in the admin alike.
    #
    # A field or action row is labelled with its name (what the gem writes
    # for a row it generates, and what PermissionForge::GeneratedText reads
    # as no label); the field's column is NOT NULL, so nil cannot stand for
    # "no label" there. A Resource stores nil (its label column is nullable
    # and the admin names a model from the host's translation).
    #
    # A rename that leaves a generated label as it was relabels the row with
    # its new name: the old name would read as a label an admin wrote.
    #
    # Checked on create, when the label changes and on a rename only: a row
    # stored with a blank label before keeps it through a save of its other
    # attributes (no label change in that save's audit event).
    #
    # Field test round 8 (D#25): through the API a field label `null` was a
    # 422 "can't be blank" while `""` was stored, and an action stored both
    # as sent — the admin stored a blanked label as the name.
    #
    # @api private
    module NormalizesLabel
      extend ActiveSupport::Concern

      included do
        before_validation :normalize_label
      end

      # What a label `text` written to this row is stored as: a blank one
      # (nil, empty, white space) as no label — the row's name (a
      # Resource: nil) — anything else as written. The admin's review asks
      # it for the value it shows.
      #
      # @param text [String, nil]
      # @return [String, nil]
      def label_to_store(text)
        text.to_s.strip.empty? ? generated_label : text
      end

      private

      # The label "no label" is stored as: the row's name.
      #
      # @return [String, nil]
      def generated_label
        name.to_s
      end

      def normalize_label
        return unless has_attribute?(:label) && label_check_due?

        self.label = unwritten_label? ? generated_label : label_to_store(label)
      end

      def label_check_due?
        new_record? || will_save_change_to_label? || will_save_change_to_name?
      end

      # On a new row the column default; on a rename, a label generated for
      # the old name that this save leaves as it is.
      def unwritten_label?
        return label == self.class.column_defaults['label'] if new_record?

        will_save_change_to_name? && !will_save_change_to_label? && !generated_label.nil? &&
          PermissionForge::GeneratedText.label?(label, name_in_database)
      end
    end
  end
end
