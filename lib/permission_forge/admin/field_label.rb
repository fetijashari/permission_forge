# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the label the admin shows for a stored field,
    # column or association name: the host application's own translation
    # when it has one (`activerecord.attributes.<model>.<name>`, read
    # through `human_attribute_name` — never its English fallback), else the
    # label of the ResourceField row, else the name verbatim (`verbatim?`:
    # the view draws it in <code>; an admin looks for the stored name).
    # Rails' `humanize` ("Full address") is English whatever the page's
    # language, so it is never used (release_readiness/inflection_guard_test.rb).
    #
    # @example
    #   FieldLabel.for(Customer, 'full_address').text          # => "Adresa" (host translation), or "full_address"
    #   FieldLabel.for('Customer', 'email', row: field).text   # => the row's label when the host has no translation
    #
    # @api private
    class FieldLabel
      # What `human_attribute_name` / `model_name.human` answer when the host
      # has no translation (their `default:`): a value never shown.
      MISSING = "\u0000permission_forge:missing\u0000"

      # A label and whether it is the stored name itself.
      Label = Data.define(:text, :verbatim) do
        def verbatim? = verbatim
        def to_s = text
      end

      class << self
        # @param model [Class, ModelCatalog::ModelInfo, String, nil] the model the name belongs to
        # @param name [String, Symbol] the stored name
        # @param row [#label, nil] the ResourceField (anything with a `label`) for the name
        # @return [Label]
        def for(model, name, row: nil)
          name = name.to_s
          translated = host_translation(model, name)
          return Label.new(text: translated, verbatim: false) if translated

          label = row.respond_to?(:label) ? row.label.to_s.strip : ''
          label.empty? ? Label.new(text: name, verbatim: true) : Label.new(text: label, verbatim: false)
        end

        # The host's translation of `name` on `model`, or nil. An empty name
        # (a doubled dot in a path) is no attribute: never asked.
        #
        # @return [String, nil]
        def host_translation(model, name)
          klass = klass_of(model)
          return nil if name.blank? || !klass.respond_to?(:human_attribute_name)

          value = klass.human_attribute_name(name, default: MISSING)
          value == MISSING ? nil : value
        end

        # The model class behind a Class, a ModelCatalog::ModelInfo or a
        # stored Resource name (validated by Resource::NAME_FORMAT).
        def klass_of(model)
          return model.klass if model.respond_to?(:klass)
          return model.to_s.safe_constantize if model.is_a?(String) || model.is_a?(Symbol)

          model
        end
      end
    end
  end
end
