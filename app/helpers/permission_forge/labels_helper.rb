module PermissionForge
  # Labels of stored names in the page's language: a field, column or
  # association name (Admin::FieldLabel), a model or Resource
  # (Admin::ModelLabel), an action (Admin::ActionLabel) — the host's own
  # translation when it has one, else the row's label, else the name
  # verbatim, drawn in <code>. Never Rails' English inflections
  # (release_readiness/inflection_guard_test.rb).
  #
  # @api private
  module LabelsHelper
    # --- labels of stored names --------------------------------------------------

    # The label of a stored field, column or association name
    # (Admin::FieldLabel): the host's translation, else the row's label,
    # else the name verbatim — then drawn in <code>, as a stored name is.
    def pf_field_label(model, name, row: nil)
      label = pf_field_label_for(model, name, row: row)
      label.verbatim? ? tag.code(label.text, class: 'pf-mono-key') : label.text
    end

    # The same label as plain text (an attribute, a title, an option).
    def pf_field_label_text(model, name, row: nil)
      pf_field_label_for(model, name, row: row).text
    end

    # @return [Admin::FieldLabel::Label]
    def pf_field_label_for(model, name, row: nil)
      PermissionForge::Admin::FieldLabel.for(model, name, row: row)
    end

    # The label of an action (Admin::ActionLabel): the row's label, else the
    # key verbatim, as text.
    def pf_action_label_text(action, key = action&.name)
      PermissionForge::Admin::ActionLabel.for(action, key).text
    end

    # The plural label of a model (Admin::ModelLabel): the host's plural
    # translation, else "<label> records" in the page's language.
    def pf_resource_plural(name)
      PermissionForge::Admin::ModelLabel.plural(name)
    end

    # The label of a Resource or model name (Admin::ModelLabel): the row's
    # label, else the host's translation, else the constant's name.
    def pf_resource_label(resource_or_name)
      PermissionForge::Admin::ModelLabel.for(resource_or_name).text
    end
  end
end
