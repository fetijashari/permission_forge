# frozen_string_literal: true

module PermissionForge
  module Admin
    # The one definition of the label the admin shows for a model (a
    # Resource): the Resource row's own label when an admin gave it one,
    # else the host application's translation (`activerecord.models.<model>`,
    # through `model_name.human` — never its English fallback), else the
    # constant's name verbatim ("Billing::Invoice"). The plural ("Only show
    # [Customers] where …") is the host's plural translation when it has
    # one, else `permission_forge.ui.resource_plural` around the label:
    # Rails' `pluralize` is English whatever the page's language.
    #
    # @example
    #   ModelLabel.for(resource).text        # => "Clients" (the row's label), "Kunde" (host), or "Customer"
    #   ModelLabel.plural('Customer')        # => "Customers" (host translation), else "Customer records"
    #
    # @api private
    class ModelLabel
      class << self
        # @param resource_or_name [Resource, #name, String, Class, ModelCatalog::ModelInfo]
        # @return [FieldLabel::Label] verbatim when the text is the constant's name
        def for(resource_or_name)
          label = row_label(resource_or_name)
          return FieldLabel::Label.new(text: label, verbatim: false) if label

          name = name_of(resource_or_name)
          translated = host_translation(name)
          translated ? FieldLabel::Label.new(text: translated, verbatim: false) : FieldLabel::Label.new(text: name, verbatim: true)
        end

        # @param name [String, Class, #name] the model
        # @return [String]
        def plural(name)
          host_translation(name_of(name), count: 2) ||
            I18n.t('permission_forge.ui.resource_plural', name: self.for(name).text, count: 2)
        end

        # The host's translation of the model's name, or nil.
        #
        # @return [String, nil]
        def host_translation(name, count: 1)
          klass = FieldLabel.klass_of(name)
          return nil unless klass.respond_to?(:model_name)

          value = klass.model_name.human(count: count, default: FieldLabel::MISSING)
          value == FieldLabel::MISSING ? nil : value
        end

        private

        def row_label(resource)
          return nil unless resource.respond_to?(:label) && !resource.is_a?(Class)

          resource.label.to_s.strip.presence
        end

        def name_of(resource_or_name)
          return resource_or_name.name.to_s if resource_or_name.respond_to?(:name) && !resource_or_name.is_a?(String)

          resource_or_name.to_s
        end
      end
    end
  end
end
