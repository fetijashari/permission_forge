# frozen_string_literal: true

module PermissionForge
  # What #inspect hides on the gem's own models. Rails copies
  # config.filter_parameters into ActiveRecord::Base.filter_attributes, so
  # the GDPR patterns PermissionForge adds there (filter_parameters_integration:
  # `\Aname\z`, …) also hid the *configuration* names of the gem's rows: a
  # console printed `#<PermissionForge::PermissionSet … name: [FILTERED]>` for a
  # set called "Sales rep", and a ResourceField's `name` (a column name such as
  # "email") the same way.
  #
  # Each model sets its own list with Rails' `filter_attributes=` as its
  # class body runs (after config/initializers, again after a reload):
  #
  # - .show_configuration_names: the inherited filters, each made unable to
  #   match the model's configuration-name attributes (`name`, `label`,
  #   `field_name`) — they keep hiding every other attribute they matched (a
  #   rule's `field_value` or `failure_message`, a description). A Proc filter
  #   is kept as it is: it decides for itself.
  # - .hide_people_labels (AuditEvent): the inherited filters plus the
  #   labels that name people (`actor_label`, `record_label`, which
  #   DataSubjectErasure scrubs), whenever the inherited filters hide a
  #   person's `name` — with the GDPR patterns, or a host's own `:name`.
  #
  # Only Regexps are added, so Rails 8's FilterAttributeHandler (which copies a
  # model's String and Symbol entries back into config.filter_parameters as
  # "model.attribute") adds nothing to the host's request-parameter filter.
  # Request parameters, SQL bind logging (ActiveRecord::Base's filter) and the
  # host's models are untouched. A filter added to
  # ActiveRecord::Base.filter_attributes after a model has loaded does not
  # reach it until the next reload.
  #
  # @api private
  module InspectionFilters
    # The attributes of the gem's models that hold configuration names.
    CONFIGURATION_NAMES = %w[name label field_name].freeze
    # AuditEvent's labels that name a person.
    PEOPLE_LABELS = %w[actor_label record_label].freeze

    module_function

    # @param klass [Class] a model of the gem
    # @return [void]
    def show_configuration_names(klass, names = CONFIGURATION_NAMES)
      klass.filter_attributes = sparing(klass.superclass.filter_attributes, names)
    end

    # @param klass [Class] PermissionForge::AuditEvent
    # @return [void]
    def hide_people_labels(klass, labels = PEOPLE_LABELS)
      inherited = klass.superclass.filter_attributes
      return unless hides?(inherited, 'name')

      klass.filter_attributes = inherited + [/\A(?:#{labels.map { |label| Regexp.escape(label) }.join('|')})\z/]
    end

    # `filters` (a filter_attributes list) with every String, Symbol and
    # Regexp turned into a Regexp that matches what it matched, except the
    # attribute names `names` themselves. A String or Symbol matches as Rails
    # reads it: anywhere in the name, ignoring case.
    #
    # @return [Array]
    def sparing(filters, names)
      guard = "\\A(?!(?:#{names.map { |name| Regexp.escape(name.to_s) }.join('|')})\\z).*?"
      filters.map do |filter|
        case filter
        when Proc then filter
        when Regexp
          # Under /x a trailing comment would swallow the closing parenthesis.
          Regexp.new("#{guard}(?:#{filter.source}#{"\n" if filter.options.anybits?(Regexp::EXTENDED)})", filter.options)
        else Regexp.new("#{guard}(?:#{Regexp.escape(filter.to_s)})", Regexp::IGNORECASE)
        end
      end
    end

    def hides?(filters, attribute)
      ActiveSupport::ParameterFilter.new(filters).filter_param(attribute, 'x') != 'x'
    end
  end
end
