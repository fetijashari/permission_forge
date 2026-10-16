# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the label the admin shows for a stored field,
    # column or association name: the host application's own translation
    # when it has one (`activerecord.attributes.<model>.<name>`, read
    # through `human_attribute_name` with a sentinel default), else the label
    # an admin wrote on the ResourceField row — a label the gem generated
    # (PermissionForge::GeneratedText.label?: blank, the name, the name
    # humanized, 'Untitled Field') is no label — else, on an English page,
    # Rails' own English for the name (`human_attribute_name`: "Created at",
    # what an English host saw before 0.15; #english), else the name
    # verbatim (`verbatim?`: the view draws it in <code>; an admin looks for
    # the stored name). Rails' English is never shown on a page in another
    # language (release_readiness/inflection_guard_test.rb). A column with
    # no row and one with a generated label read the same (field test round
    # 7, B#26).
    #
    # @example
    #   FieldLabel.for(Customer, 'full_address').text          # => "Adresa" (host translation); on sq "full_address", on en "Full address"
    #   FieldLabel.for('Customer', 'email', row: field).text   # => the label an admin wrote, when the host has no translation
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

          label = written_label(row, name)
          return Label.new(text: label, verbatim: false) if label

          fallback(klass_of(model), name)
        end

        # The label an admin wrote on `row`, or nil for none — a label the
        # gem generated (GeneratedText.label?) is none.
        #
        # @return [String, nil]
        def written_label(row, name)
          label = row.respond_to?(:label) ? row.label.to_s.strip : ''
          label unless PermissionForge::GeneratedText.label?(label, name)
        end

        # A name with no translation and no label of the admin's: Rails' own
        # English on an English page (#english), the name verbatim elsewhere
        # — and wherever the model cannot be loaded (the stored name is what
        # the admin looks for).
        #
        # @param klass [Class, nil] the model the name belongs to, when known
        # @return [Label]
        def fallback(klass, name)
          text = english(name) { klass.human_attribute_name(name) if klass.respond_to?(:human_attribute_name) }
          text ? Label.new(text: text, verbatim: false) : Label.new(text: name.to_s, verbatim: true)
        end

        # Rails' English for a name, only while the page is English: what
        # the block answers (a model's `human_attribute_name`: "Created at"),
        # or without a block Rails' humanization of the name (an action key,
        # which belongs to no attribute: "Export csv"). nil on any other
        # page, and for a blank name.
        #
        # @return [String, nil]
        def english(name)
          return nil if name.blank? || !I18n.locale.to_s.start_with?('en')

          block_given? ? yield : ActiveSupport::Inflector.humanize(name)
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
          return PermissionForge::ModelLookup.model_for(model) if model.is_a?(String) || model.is_a?(Symbol)

          model
        end
      end
    end
  end
end
