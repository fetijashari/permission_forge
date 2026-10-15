module PermissionForge
  # Labels and links for audit rows (Person → Audit, Permission Set → Audit,
  # CSV) and for audit events (the audit log, the timelines, an event).
  #
  # @api private
  module AuditHelper
    # Every category has a glyph and a word (never colour alone).
    CATEGORY_GLYPHS = { 'change' => '✎', 'admin' => '⚑', 'system' => '⚙', 'access' => '◉' }.freeze
    CATEGORY_VARIANTS = { 'change' => :changed, 'admin' => :warn, 'system' => :default, 'access' => :mask }.freeze
    # The message Audit::EventQuery gives a filter that needs a value (Rails' own).
    QUERY_BLANK_MESSAGE = 'errors.messages.blank'.freeze
    # [record label, where] per audited type; evaluated in the view context.
    AUDIT_LABELS = {
      'permission_set' => ->(record) { [record.name, nil] },
      'group' => ->(record) { [record.name, nil] },
      'resource' => ->(record) { [pf_resource_label(record), record.permission_set&.name] },
      'field' => ->(record) { [record.label.presence || record.name, pf_audit_resource_where(record.resource)] },
      'action' => ->(record) { [record.label.presence || record.name, pf_audit_resource_where(record.resource)] },
      'rule' => ->(record) { [record.name, pf_audit_resource_where(record.resource)] },
      'assignment' => ->(record) { [pf_person_name(record.user), record.permission_set&.name] },
      'group_membership' => ->(record) { [pf_person_name(record.user), record.permission_set_group&.name] }
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

    # [type label, record label, where] — also used for CSV export.
    def pf_audit_describe(entry)
      record = entry.record
      label, where = pf_audit_label_and_where(entry.type, record)
      [pf_audit_type_label(entry.type), label, where]
    end

    def pf_audit_label_and_where(type, record)
      pf_audit_lookup(AUDIT_LABELS, type, record)
    end

    def pf_audit_resource_where(resource)
      return nil unless resource

      "#{resource.permission_set&.name} › #{pf_resource_label(resource)}"
    end

    def pf_audit_path(entry)
      pf_audit_lookup(AUDIT_PATHS, entry.type, entry.record)
    end

    # Runs the registry entry for `type` in the view context; nil for unknown types.
    def pf_audit_lookup(registry, type, record)
      handler = registry[type]
      instance_exec(record, &handler) if handler
    end

    def pf_audit_nested_path(resource, kind, key)
      return nil unless resource

      case kind
      when :field then permission_forge.permission_set_resource_field_path(resource.permission_set_id, resource.name, key)
      when :action then permission_forge.permission_set_resource_action_path(resource.permission_set_id, resource.name, key)
      when :rule then permission_forge.edit_permission_set_resource_rule_path(resource.permission_set_id, resource.name, key)
      end
    end

    def pf_audit_who_when(person, time, relative: false)
      t('permission_forge.ui.audit.who_when', who: pf_person_name(person),
                                              when: relative ? pf_relative(time) : pf_date(time))
    end

    # --- audit events ---------------------------------------------------------

    # Who acted, as recorded: the name snapshot, with what kind of actor it
    # was when that is not a person ("ops (password prompt)", "API client").
    def pf_audit_actor_name(event)
      type = event.actor_type.to_s
      label = event.actor_label.presence
      return t("permission_forge.audit_log.actor_named.#{type}", name: label, default: label) if label
      return t('permission_forge.audit_log.person_id', id: event.actor_id) if type == 'user' && event.actor_id.present?

      pf_audit_actor_type_label(type)
    end

    # An event that named no actor (code outside a request with no
    # PermissionForge.with_audit_actor, or an actor resolver that failed):
    # pf_audit_actor_name reads it as the actor type "Unknown".
    def pf_audit_unknown_actor?(event)
      !event.nil? && event.actor_type.to_s == 'unknown' && event.actor_label.blank?
    end

    # Where "Unknown" comes from, said the same way wherever it shows. The
    # record footer names it first ("Unknown: no actor was named…"); the event
    # page shows it right above as the actor (`named: false`), so the
    # explanation does not repeat the word.
    def pf_audit_unknown_actor_hint(named: true)
      method = tag.code('PermissionForge.with_audit_actor')
      return t('permission_forge.audit_events.show.unknown_actor_html', method: method) unless named

      t('permission_forge.shared.audit_footer.unknown_hint_html', unknown: pf_audit_actor_type_label('unknown'), method: method)
    end

    def pf_audit_actor_type_label(type)
      t("permission_forge.audit_log.actor_types.#{type}", default: type.to_s.humanize)
    end

    def pf_audit_category_label(category)
      t("permission_forge.audit_log.categories.#{category}", default: category.to_s.humanize)
    end

    def pf_audit_source_label(source)
      t("permission_forge.audit_log.sources.#{source}", default: source.to_s.humanize)
    end

    def pf_audit_category_badge(category)
      pf_badge("#{CATEGORY_GLYPHS.fetch(category.to_s, '•')} #{pf_audit_category_label(category)}",
               variant: CATEGORY_VARIANTS.fetch(category.to_s, :default))
    end

    def pf_audit_event_path(event, **)
      permission_forge.audit_event_path(event.uuid, **)
    end

    # The audit log, filtered (only the filters given).
    def pf_audit_log_path(**filters)
      permission_forge.audit_events_path(filters.compact_blank)
    end

    # The person an event is about: the label an assignment's or a
    # membership's event kept (their name then), else the user when they
    # still exist, else their id.
    def pf_audit_person_name(event, lookups)
      id = event.subject_user_id
      return nil if id.blank?

      return event.record_label if pf_audit_person_record?(event) && event.record_label.present?

      user = lookups.person(id)
      return pf_person_name(user) if user

      t('permission_forge.audit_log.person_id', id: id)
    end

    def pf_audit_person_record?(event)
      %w[PermissionForge::PermissionSetUser PermissionForge::PermissionSetGroupUser].include?(event.record_type)
    end

    # The Permission Set's name when the event happened (AuditLookups), or
    # what the event says about it.
    def pf_audit_set_name(event, lookups)
      return nil if event.permission_set_id.blank? && event.permission_set_uuid.blank?
      return event.record_label if event.record_type == 'PermissionForge::PermissionSet' && event.record_label.present?

      name = lookups.permission_set_name(event)
      return name if name

      t('permission_forge.audit_log.deleted_set', id: event.permission_set_id || event.permission_set_uuid)
    end

    def pf_audit_group_name(event, lookups)
      name = lookups.group_name(event)
      return name if name

      id = PermissionForge::Admin::AuditLookups.group_id(event)
      id ? t('permission_forge.audit_log.deleted_group', id: id) : t('permission_forge.audit_log.unknown_group')
    end

    # What the event is about: its label snapshot, else type and id.
    def pf_audit_record_name(event)
      return event.record_label if event.record_label.present?
      return '' if event.record_type.blank?

      [event.record_type.to_s.demodulize.titleize, event.record_id || event.record_uuid].compact.join(' #')
    end

    # A value of a before/after or snapshot table: text as it is, nothing as
    # a dash-word, anything else as JSON.
    def pf_audit_value(value)
      case value
      when nil then t('permission_forge.audit_log.no_value')
      when String then value.empty? ? t('permission_forge.audit_log.empty_text') : value
      when true, false then t("permission_forge.audit_log.boolean.#{value}")
      when Numeric then value.to_s
      else ActiveSupport::JSON.encode(value)
      end
    end

    # One line per refused filter, in the admin's own words (EventQuery's
    # messages are Rails' errors.messages, which a host may not translate):
    # a value that is needed, or the value that is not valid.
    def pf_audit_filter_error(name, messages, value)
      field = t("permission_forge.audit_events.index.filters.#{name}", default: name.to_s.humanize)
      scope = 'permission_forge.audit_events.index.invalid'
      return t("#{scope}.blank", field: field) if Array(messages).include?(I18n.t(QUERY_BLANK_MESSAGE))
      return t("#{scope}.invalid", field: field) if value.blank?

      t("#{scope}.invalid_value", field: field, value: value.truncate(80))
    end

    # The first scalar of a filter parameter (a list or a hash shows nothing).
    def pf_audit_filter_value(filters, key)
      value = filters[key]
      value.is_a?(String) ? value : nil
    end
  end
end
