# frozen_string_literal: true

module PermissionForge
  module Admin
    # How the admin names who made a change — the one definition the record
    # footers, the event page, the audit tabs and their CSV, "Assigned by" and
    # the event sentences use: a label the gem stored as a code
    # (Audit::ActorCodes: an API client nobody named, the boot) in the
    # page's language, else the event's actor label (with its kind where
    # it is not a person: "admin (password prompt)"), else "Person #<id>",
    # else the actor kind's word (StateLabel kind :actor: "System",
    # "Unknown"). A record with no event and no created_by / updated_by is
    # "System" (#system).
    #
    # @api private
    module ActorLabel
      module_function

      # @param event [PermissionForge::AuditEvent]
      # @return [String]
      def for(event)
        type = event.actor_type.to_s
        label = event.actor_label.presence
        code = PermissionForge::Audit::ActorCodes.code(type, label)
        return I18n.t("permission_forge.audit_log.actor_codes.#{code}") if code
        return I18n.t("permission_forge.audit_log.actor_named.#{type}", name: label, default: label) if label
        return I18n.t('permission_forge.audit_log.person_id', id: event.actor_id) if type == 'user' && event.actor_id.present?

        type_label(type)
      end

      # The word of an actor kind; a kind outside the catalogue as stored.
      #
      # @param type [String, Symbol]
      # @return [String]
      def type_label(type) = StateLabel.word(:actor, type, default: type.to_s)

      # Whether the event names nobody: its actor kind is unknown and it has no label.
      #
      # @param event [PermissionForge::AuditEvent, nil]
      # @return [Boolean]
      def unknown?(event)
        !event.nil? && event.actor_type.to_s == 'unknown' && event.actor_label.blank?
      end

      # Who a record with no event and no person stamped on it was changed by.
      #
      # @return [String]
      def system = StateLabel.word(:actor, :system)
    end
  end
end
