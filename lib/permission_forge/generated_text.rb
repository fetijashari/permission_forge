# frozen_string_literal: true

module PermissionForge
  # The one definition of "this stored text is a default the gem generated",
  # not something an admin wrote. Through 0.15 the gem stored English it had
  # made up — a field or action row's label (`name.humanize`, the install
  # migration's 'Untitled Field'), a rule's blocked message and the names of
  # a set, a group or a rule created without one (the install migration's
  # column defaults) — and showed it as if an admin had typed it, in every
  # language. The writers store the name itself now and the models store
  # nothing for a message or name nobody wrote; the rows stored before keep
  # their text (no data is rewritten), and whatever displays one asks here
  # and renders the locale's own words instead.
  #
  # Asked by PermissionRuleApplier.failure_message_for (a denial's
  # message), the admin's labels (Admin::FieldLabel, Admin::ActionLabel) and
  # the admin's names and prefills.
  #
  # @example
  #   GeneratedText.label?('Owner', 'owner_id')                         # => true
  #   GeneratedText.failure_message?('You do not have permission to perform this action.') # => true
  #   GeneratedText.name?('Untitled Rule', :permission_set_rule)        # => true
  #
  # @api private
  module GeneratedText
    # The label the install migration gives a field row (the column default).
    UNTITLED_FIELD = 'Untitled Field'
    # The names the install migration gave a set, a group and a rule created
    # without one (the column defaults of installs made before 0.15), by kind
    # (the model's `model_name.element`).
    NAMES = {
      permission_set: 'Untitled Permission Set',
      permission_set_group: 'Untitled Permission Set Group',
      permission_set_rule: 'Untitled Rule'
    }.freeze
    # The blocked messages the install migration gave a rule created without
    # one (the column default of installs made before 0.15).
    FAILURE_MESSAGES = ['You do not have permission to perform this action.'].freeze

    module_function

    # Whether a field or action row's label is nothing an admin wrote: blank,
    # the name itself, the name humanized (what the gem stored through 0.15)
    # or the install default. A label an admin typed that happens to equal
    # the humanized name reads the same as one the gem generated — and as
    # what Rails' own English would show for it.
    #
    # @param text [String, nil] the stored label
    # @param name [String, Symbol] the row's name (a column, a virtual field, an action key)
    # @return [Boolean]
    def label?(text, name)
      label = text.to_s.strip
      return true if label.empty? || label == UNTITLED_FIELD

      name = name.to_s
      label == name || label == name.to_s.humanize
    end

    # Whether a rule's blocked message is the install migration's default.
    #
    # @param text [String, nil] the stored failure_message
    # @return [Boolean]
    def failure_message?(text)
      FAILURE_MESSAGES.include?(text.to_s.strip)
    end

    # Whether a set's, group's or rule's name is the install migration's
    # default for its kind.
    #
    # @param text [String, nil] the stored name
    # @param kind [Symbol, Class, ActiveRecord::Base] :permission_set,
    #   :permission_set_group or :permission_set_rule — or the model (class or record)
    # @return [Boolean]
    def name?(text, kind)
      NAMES[kind_of(kind)] == text.to_s.strip
    end

    # Every text the install migration has given a column of the nine tables
    # (an upgraded install still has them as column defaults): what no form
    # may pre-fill.
    #
    # @return [Array<String>]
    def install_defaults
      [UNTITLED_FIELD, *NAMES.values, *FAILURE_MESSAGES]
    end

    def kind_of(kind)
      kind = kind.class if kind.is_a?(ActiveRecord::Base)
      kind.respond_to?(:model_name) ? kind.model_name.element.to_sym : kind.to_s.to_sym
    end
    private_class_method :kind_of
  end
end
