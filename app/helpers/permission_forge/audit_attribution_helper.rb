module PermissionForge
  # Who created and who last edited a permission record, as the audit log
  # names them: the one definition the footers, the Assignments tab,
  # "Assigned by" and the audit tabs (and their CSV) use — the record's
  # creation event (Admin::LastChanges.creations) or latest change event
  # (Admin::LastChanges#last_edit), else the created_by / updated_by columns.
  #
  # @api private
  module AuditAttributionHelper
    # "Who · when" of an entry's creation: the creation event's actor when
    # there is one (as the audit log names them), else created_by.
    def pf_audit_created(entry)
      t('permission_forge.ui.audit.who_when', who: pf_audit_entry_creator(entry), when: pf_date(entry.created_at))
    end

    # The creator of an Admin::AuditTrail entry (its creation_event is preloaded).
    def pf_audit_entry_creator(entry)
      event = entry.creation_event
      event ? pf_audit_actor_name(event) : pf_person_name(entry.created_by)
    end

    # Who created a permission record, as the audit log names them — the one
    # definition wherever the admin shows it (footers, assignment rows, the
    # audit tabs): the actor of the record's creation event when the log has
    # one (an HTTP Basic login or an API client stamps no created_by), else
    # created_by, else "System". `creations` is a pf_audit_creations lookup
    # over the page's records; without one that covers the record, the
    # page's preloaded lookup or a lookup of its own is used.
    def pf_audit_creator(record, creations = nil)
      lookup = [creations, @pf_creations].find { |candidate| candidate&.covers?(record) }
      event = (lookup || pf_audit_creations([record]))[record]
      event ? pf_audit_actor_name(event) : pf_person_name(record.try(:created_by))
    end

    # The creation events of `records` in one lookup (two queries per type).
    def pf_audit_creations(records)
      PermissionForge::Admin::LastChanges.creations(records)
    end

    # "Who · when" of an entry's last edit: the latest change event's actor
    # and time when there is one, else updated_by / updated_at.
    def pf_audit_edited(entry)
      return pf_audit_who_when(entry.updated_by, entry.updated_at, relative: true) unless entry.last_event

      t('permission_forge.ui.audit.who_when', who: pf_audit_actor_name(entry.last_event), when: pf_relative(entry.updated_at))
    end

    # The record's last edit as an event (who really made it), or nil when
    # the audit log has none for it or the record was edited after it.
    # Uses the page's preloaded lookup when it covers the record.
    def pf_audit_last_change(record)
      lookup = @pf_last_changes if @pf_last_changes&.covers?(record)
      (lookup || PermissionForge::Admin::LastChanges.new([record])).last_edit(record)
    end

    # One lookup of the edits and one of the creations (pf_audit_creator)
    # for every footer the page shows. Nothing while the audit trail is off.
    def pf_audit_preload_last_changes(records)
      return unless PermissionForge.configuration.audit_trail_enabled

      @pf_last_changes = PermissionForge::Admin::LastChanges.new(records)
      @pf_creations = pf_audit_creations(records)
      nil
    end

    # [created by, last edited by] names for the audit-trail CSV.
    def pf_audit_people(entry)
      edited_by = entry.last_event ? pf_audit_actor_name(entry.last_event) : pf_person_name(entry.updated_by)
      [pf_audit_entry_creator(entry), edited_by]
    end
  end
end
