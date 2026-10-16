module PermissionForge
  # Labels of stored names in the page's language: a field, column or
  # association name (Admin::FieldLabel), a model or Resource
  # (Admin::ModelLabel), an action (Admin::ActionLabel) — the host's own
  # translation when it has one, else the label an admin wrote, else (on an
  # English page) Rails' English, else the name verbatim, drawn in <code>
  # — and the names of sets, groups and rules (Admin::RecordName), what a
  # form pre-fills (Admin::Prefill). Never Rails' English inflections on a
  # page in another language (release_readiness/inflection_guard_test.rb).
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

    # Text of the host (a label, a description, a stored value) drawn as it
    # is, marked so the locale-leak test tells it from the gem's own words.
    #
    # @return [ActiveSupport::SafeBuffer]
    def pf_host_data(text, tag_name = :span)
      content_tag(tag_name, text, data: { pf_host_data: true })
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

    # The name of a Permission Set, group or rule (Admin::RecordName): as
    # stored, except an install-default English name, named in the page's
    # language.
    def pf_record_name(record)
      PermissionForge::Admin::RecordName.for(record)
    end

    # A stored name of `kind` without its record (a list a service answered,
    # an event's label): Admin::RecordName.text.
    def pf_record_name_text(name, kind)
      PermissionForge::Admin::RecordName.text(name, kind)
    end

    # What a form's text field shows for a stored attribute (Admin::Prefill):
    # never a column default of a new record, nor text the gem generated.
    def pf_prefill(record, attribute)
      record ? PermissionForge::Admin::Prefill.text(record, attribute) : ''
    end

    # Whether a required text field may be sent blank: the stored value is
    # generated text the form shows as blank (#pf_prefill), and a blank
    # posted over it is no change (Admin::Prefill.posted). Such a field
    # drops `required`, so a page saves with and without JavaScript alike.
    def pf_prefill_optional?(record, attribute)
      return false unless record&.persisted?

      record.public_send(attribute).to_s.present? && pf_prefill(record, attribute).empty?
    end

    # A Permission Set named on a row about one of its Resources: "<set> ·
    # <Model>" when the set holds more than one Resource of `chain` (a
    # single-table-inheritance base and its subclass: Admin::ChainEntries),
    # the model marked as host data; the set's name alone otherwise (round 7,
    # B#35).
    #
    # @param set [PermissionSet]
    # @param resource_name [String] the Resource the row is about
    # @param chain [Array<String>] the Resource names of the chain the list is about
    def pf_set_entry_name(set, resource_name, chain)
      name = pf_record_name(set)
      return name unless PermissionForge::Admin::ChainEntries.several?(set, chain)

      safe_join([name, ' · ', pf_host_data(pf_resource_label(resource_name))])
    end

    # #pf_set_entry_name on a row about records of `leaf_name` (a person's
    # effective access): the chain is the leaf's ResourceChain; `entry_name`
    # the Resource the row's set acts through (an STI base whose entry
    # decides, or the leaf itself).
    def pf_chain_set_name(set, leaf_name, entry_name = leaf_name)
      @pf_chains ||= {}
      chain = (@pf_chains[leaf_name.to_s] ||= PermissionForge::ResourceChain.names_for(leaf_name).map(&:to_s))
      pf_set_entry_name(set, entry_name, chain)
    end
  end
end
