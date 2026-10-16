# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the label the admin shows for an action: the
    # label an admin wrote on the ResourceAction row — one the gem generated
    # (PermissionForge::GeneratedText.label?: blank, the key, the key
    # humanized) is none — else, on an English page, Rails' English for the
    # key ("Export csv", what an English host saw before 0.15:
    # FieldLabel.english), else the key verbatim ("export_csv"; `verbatim?`:
    # the view draws it in <code>). An action with a row and one without
    # read the same.
    #
    # @example
    #   ActionLabel.for(action).text           # => "Export to CSV" (the admin's label); "export_csv" on sq, "Export csv" on en
    #   ActionLabel.for(nil, 'sync').verbatim?  # => true on a page that is not English
    #
    # @api private
    module ActionLabel
      # @param action [ResourceAction, #label, nil] the row, when there is one
      # @param key [String, Symbol] the action key (the row's name by default)
      # @return [FieldLabel::Label]
      def self.for(action, key = action&.name)
        key = key.to_s
        label = FieldLabel.written_label(action, key)
        return FieldLabel::Label.new(text: label, verbatim: false) if label

        english = FieldLabel.english(key)
        english ? FieldLabel::Label.new(text: english, verbatim: false) : FieldLabel::Label.new(text: key, verbatim: true)
      end
    end
  end
end
