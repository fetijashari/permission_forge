# frozen_string_literal: true

module PermissionForge
  # One plain-language sentence per audit event ("Ana gave Bo the Permission
  # Set Sales.").
  #
  # @api private
  module AuditSentencesHelper
    AUDIT_SENTENCES = 'permission_forge.audit_log.sentences'

    # Events whose sentence depends on what they recorded: event name →
    # a block (run in the view) that returns the sentence, or nil for the
    # event's own one. Adding a variant is one entry here plus its key.
    AUDIT_SENTENCE_VARIANTS = {
      # Names the fields that were hidden or masked; a read with none of
      # them is the plain "read X." sentence.
      'field.access' => lambda { |event, parts|
        fields = pf_audit_limited_fields(event)
        next if fields.empty?

        t('permission_forge.audit_log.sentence_variants.field_access_limited', **parts, fields: fields.join(', '))
      },
      # A revocation of an assignment that had already ended (the clean-up).
      'assignment.revoked' => lambda { |event, parts|
        ended = pf_audit_expired_at(event)
        next unless ended

        t('permission_forge.audit_log.sentence_variants.assignment_revoked_expired', **parts, date: pf_date(ended))
      }
    }.freeze

    # One sentence per event, from the locale key named after the event
    # (permission_forge.audit_log.sentences.<event>): a new event needs one
    # key in each locale, and an event without one (a host's own) still reads
    # as "<actor>: <event name>". Interpolations: actor, record, set, person,
    # group, event, model (a runtime event's model).
    def pf_audit_sentence(event, lookups)
      parts = pf_audit_sentence_parts(event, lookups)
      variant = AUDIT_SENTENCE_VARIANTS[event.event]
      variant &&= instance_exec(event, parts, &variant)
      return variant if variant

      fallback = t("#{AUDIT_SENTENCES}.fallback", **parts)
      sentence = t("#{AUDIT_SENTENCES}.#{event.event}", **parts, default: fallback)
      sentence.is_a?(String) ? sentence : fallback
    end

    # The hidden and masked field names a field.access event lists.
    def pf_audit_limited_fields(event)
      data = event.data || {}
      %w[hidden masked].flat_map { |key| Array(data[key]) }.map(&:to_s).uniq
    end

    # When the revoked assignment had ended, if it had ended before the
    # revocation (its snapshot's expires_at).
    def pf_audit_expired_at(event)
      snapshot = event.data.is_a?(Hash) ? event.data['snapshot'] : nil
      ended = pf_audit_time(snapshot['expires_at']) if snapshot.is_a?(Hash)
      ended if ended && event.occurred_at && ended <= event.occurred_at
    end

    def pf_audit_time(value)
      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError
      nil
    end

    def pf_audit_sentence_parts(event, lookups)
      unknown = t('permission_forge.audit_log.unknown')
      {
        actor: pf_audit_actor_name(event), record: pf_audit_record_name(event).presence || unknown,
        set: pf_audit_set_name(event, lookups) || unknown, person: pf_audit_person_name(event, lookups) || unknown,
        group: pf_audit_person_record?(event) ? pf_audit_group_name(event, lookups) : unknown, event: event.event,
        model: pf_audit_model_name(event).presence || unknown
      }
    end

    # The model a runtime event is about: data['model'], else the record type.
    def pf_audit_model_name(event)
      model = event.data.is_a?(Hash) ? event.data['model'] : nil
      (model.is_a?(String) ? model : event.record_type).to_s.demodulize
    end
  end
end
