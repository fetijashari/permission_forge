module PermissionForge
  # Labels and links for the rows of the Audit tabs' record lists (Person →
  # Audit, Permission Set → Audit, under audit_trail_enabled) and their CSV
  # exports: each record named as the admin names it on a page, as stored in
  # the CSV.
  #
  # @api private
  module AuditRecordsHelper
    # [record label, where] per audited type; evaluated in the view
    # context, `csv` true for the CSV export. On a page names and labels
    # read as everywhere else in the admin: a set's, group's or rule's
    # install-default name in the page's language (pf_record_name), a
    # field's or action's generated label as no label (Admin::FieldLabel,
    # Admin::ActionLabel; a verbatim name in <code>). The CSV keeps the
    # values as stored (an export is data, as the log's exports keep a
    # stored reason).
    AUDIT_LABELS = {
      'permission_set' => ->(record, csv) { [pf_audit_name(record, csv), nil] },
      'group' => ->(record, csv) { [pf_audit_name(record, csv), nil] },
      'resource' => ->(record, csv) { [pf_resource_label(record), pf_audit_name(record.permission_set, csv)] },
      'field' => lambda { |record, csv|
        label = csv ? pf_audit_stored_label(record) : pf_field_label(record.resource&.name, record.name, row: record)
        [label, pf_audit_resource_where(record.resource, csv)]
      },
      'action' => lambda { |record, csv|
        [csv ? pf_audit_stored_label(record) : pf_audit_action_label(record), pf_audit_resource_where(record.resource, csv)]
      },
      'rule' => ->(record, csv) { [pf_audit_name(record, csv), pf_audit_resource_where(record.resource, csv)] },
      'assignment' => ->(record, csv) { [pf_person_name(record.user), pf_audit_name(record.permission_set, csv)] },
      'group_membership' => ->(record, csv) { [pf_person_name(record.user), pf_audit_name(record.permission_set_group, csv)] }
    }.freeze

    # Link target per audited type; evaluated in the view context.
    AUDIT_PATHS = {
      'permission_set' => ->(record) { permission_forge.permission_set_path(record) },
      'resource' => ->(record) { permission_forge.permission_set_resource_path(record.permission_set_id, record.name) },
      'field' => ->(record) { pf_audit_nested_path(record.resource, :field, record.name) },
      'action' => ->(record) { pf_audit_nested_path(record.resource, :action, record.id) },
      'rule' => ->(record) { pf_audit_nested_path(record.resource, :rule, record.id) },
      'assignment' => ->(record) { permission_forge.person_path(record.user_id) },
      'group' => ->(record) { permission_forge.group_path(record) },
      'group_membership' => ->(record) { permission_forge.group_path(record.permission_set_group_id) }
    }.freeze

    def pf_audit_type_label(type)
      t("permission_forge.ui.audit.types.#{type}")
    end

    # [type label, record label, where] of a page's row (AUDIT_LABELS).
    def pf_audit_describe(entry, csv: false)
      label, where = pf_audit_lookup(AUDIT_LABELS, entry.type, entry.record, csv)
      [pf_audit_type_label(entry.type), label, where]
    end

    # [type label, record label, where] of a CSV row: stored values.
    def pf_audit_csv_describe(entry)
      pf_audit_describe(entry, csv: true)
    end

    # "<set> › <model>" for a row under a Resource.
    def pf_audit_resource_where(resource, csv)
      return nil unless resource

      "#{pf_audit_name(resource.permission_set, csv)} › #{pf_resource_label(resource)}"
    end

    # A set's, group's or rule's name: as the admin names it, or as stored for the CSV.
    def pf_audit_name(record, csv)
      csv ? record&.name : pf_record_name(record).presence
    end

    # A field's or action's label as stored, else its name (the CSV).
    def pf_audit_stored_label(row)
      row.label.presence || row.name
    end

    # An action's label (Admin::ActionLabel), a verbatim key in <code>.
    def pf_audit_action_label(action)
      label = PermissionForge::Admin::ActionLabel.for(action)
      label.verbatim? ? tag.code(label.text, class: 'pf-mono-key') : label.text
    end

    def pf_audit_path(entry)
      pf_audit_lookup(AUDIT_PATHS, entry.type, entry.record)
    end

    # Runs the registry entry for `type` in the view context; nil for unknown types.
    def pf_audit_lookup(registry, type, *)
      handler = registry[type]
      instance_exec(*, &handler) if handler
    end

    def pf_audit_nested_path(resource, kind, key)
      return nil unless resource

      case kind
      when :field then permission_forge.permission_set_resource_field_path(resource.permission_set_id, resource.name, key)
      when :action then permission_forge.permission_set_resource_action_path(resource.permission_set_id, resource.name, key)
      when :rule then permission_forge.edit_permission_set_resource_rule_path(resource.permission_set_id, resource.name, key)
      end
    end
  end
end
