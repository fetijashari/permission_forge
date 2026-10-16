# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the label the admin shows for an action: the
    # ResourceAction row's label when it has one, else the action key
    # verbatim ("export_csv"; `verbatim?`: the view draws it in <code>).
    # Never Rails' `humanize`, which is English whatever the page's language.
    #
    # @example
    #   ActionLabel.for(action).text          # => "Export to CSV" (the row's label) or "export_csv"
    #   ActionLabel.for(nil, 'sync').verbatim? # => true
    #
    # @api private
    module ActionLabel
      # @param action [ResourceAction, #label, nil] the row, when there is one
      # @param key [String, Symbol] the action key (the row's name by default)
      # @return [FieldLabel::Label]
      def self.for(action, key = action&.name)
        label = action.respond_to?(:label) ? action.label.to_s.strip : ''
        label.empty? ? FieldLabel::Label.new(text: key.to_s, verbatim: true) : FieldLabel::Label.new(text: label, verbatim: false)
      end
    end
  end
end
