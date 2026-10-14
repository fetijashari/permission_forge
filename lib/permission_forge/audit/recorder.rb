# frozen_string_literal: true

module PermissionForge
  module Audit
    # Builds the row of one event from its catalogue entry, the audit context
    # and the caller's payload, stores it (AuditEvent) and gives the
    # notification payload. The row is built once (#attributes) and kept.
    #
    # Payload keys (anything else raises — a typo must not pass silently):
    #   record:             the record the event is about. A permission model
    #                       (Concerns::RecordsAuditEvents) fills its columns
    #                       through #audit_reference. Any other record fills
    #                       record_type (its base class), record_id and, when
    #                       the table has a uuid column, record_uuid from the
    #                       raw column — never through its readers, which a
    #                       masked host model guards, and never a label
    #   record_label:       the label of a host record, if any
    #   data:               event-specific Hash, stored as JSON with string keys
    #   reason:             free text or ticket reference
    #   actor:              an Actor, a user or a Hash — overrides Actor.current
    #   source:             overrides Source.current
    #   subject_user_id:    the person whose access is affected
    #   permission_set:     a PermissionSet (fills id and uuid) or an id
    #   occurred_at:        defaults to now (UTC)
    #   record_type, record_id, record_uuid, permission_set_id,
    #   permission_set_uuid, tenant_id: column overrides
    #   ambient_tenant_id:  the tenant that was ambient when the event
    #                       happened, for an event written later
    #                       (Audit::Detached); defaults to the one ambient now
    #   objects:            live objects for the subscribers in this process
    #                       (the user a decision was made for, …): handed over
    #                       as payload[:objects], never stored or serialized
    #
    # @api private
    class Recorder
      OPTIONS = %i[record data reason actor source subject_user_id permission_set occurred_at
                   record_type record_id record_uuid record_label permission_set_id permission_set_uuid tenant_id
                   ambient_tenant_id objects].freeze
      NO_OBJECTS = {}.freeze
      REFERENCE_COLUMNS = %i[record_type record_id record_uuid record_label permission_set_id permission_set_uuid
                             subject_user_id tenant_id].freeze

      attr_reader :entry

      # @param entry [EventCatalog::Entry]
      # @param payload [Hash] see OPTIONS
      def initialize(entry, payload)
        unknown = payload.keys - OPTIONS
        raise ArgumentError, "unknown audit payload key(s) #{unknown.map(&:inspect).join(', ')} (known: #{OPTIONS.join(', ')})" \
          unless unknown.empty?

        @entry = entry
        @payload = payload
      end

      def name
        entry.name
      end

      # The event as a Hash: every column of AuditEvent (uuid included) plus
      # tenant_id. What subscribers receive, with stored: and audit_event:.
      # Every string column is cleaned (Audit::ColumnValues).
      def attributes
        @attributes ||= ColumnValues.clean(raw_attributes).freeze
      end

      # @return [AuditEvent] the stored event
      def store!
        PermissionForge::AuditEvent.store!(attributes.except(:tenant_id).merge(subject_tenant_id: attributes[:tenant_id]))
      end

      # @param stored [AuditEvent, nil]
      # @param deferred [Boolean] the row is written later: a runtime event
      #   heard inside an open transaction is stored once the outermost
      #   transaction has ended (Audit.instrument)
      def notification_payload(stored, deferred: false)
        attributes.merge(stored: !stored.nil?, audit_event: stored, deferred: deferred,
                         objects: @payload[:objects] || NO_OBJECTS)
      end

      private

      def raw_attributes
        {
          uuid: Audit.new_id, event: entry.name, category: entry.category,
          **actor.to_columns, source: source,
          **reference,
          data: data, reason: reason,
          request_id: Context[:request_id], ip: Context[:ip],
          correlation_id: correlation_id, occurred_at: occurred_at
        }
      end

      def actor
        Actor.coerce(@payload[:actor]) || Actor.current
      end

      def source
        @payload[:source] ? Source.validate!(@payload[:source]) : Source.current
      end

      def reason
        (@payload[:reason] || Context[:reason])&.to_s
      end

      def data
        (@payload[:data] || {}).as_json
      end

      def occurred_at
        (@payload[:occurred_at] || Time.current).utc
      end

      # The context's id, else one per open transaction, else one of its own:
      # a correlation id is never blank.
      def correlation_id
        Context[:correlation_id] || Context.transaction_correlation_id || Audit.new_id
      end

      # Columns from the record, then from permission_set:, then explicit overrides.
      def reference
        columns = REFERENCE_COLUMNS.index_with { nil }.merge!(record_reference, permission_set_reference,
                                                              @payload.slice(*REFERENCE_COLUMNS))
        columns[:record_id] = columns[:record_id]&.to_s
        columns[:subject_user_id] = columns[:subject_user_id]&.to_s
        columns[:tenant_id] = ambient_tenant_id if columns[:tenant_id].nil?
        columns
      end

      # Pinned when the event is built: a row written later (after the
      # transaction it was noticed in has ended) keeps the tenant of the
      # moment it happened, whatever is ambient at the write.
      def ambient_tenant_id
        @payload.key?(:ambient_tenant_id) ? @payload[:ambient_tenant_id] : PermissionForge.ambient_tenant_id
      end

      def record_reference
        record = @payload[:record]
        return {} unless record
        return record.audit_reference if record.respond_to?(:audit_reference)

        { record_type: record_type_of(record), record_id: record.id, record_uuid: raw_uuid_of(record) }
      end

      def record_type_of(record)
        klass = record.class
        klass.respond_to?(:base_class) ? klass.base_class.name : klass.name
      end

      # The uuid column as stored, past the record's readers (a host model
      # with MaskedAttributes guards those, and a guard that audits reads
      # would recurse).
      def raw_uuid_of(record)
        return unless record.respond_to?(:has_attribute?) && record.has_attribute?('uuid')

        record.read_attribute_before_type_cast('uuid')
      end

      def permission_set_reference
        set = @payload[:permission_set]
        return {} unless set
        return { permission_set_id: set.id, permission_set_uuid: set.uuid } if set.respond_to?(:uuid)

        { permission_set_id: set }
      end
    end
  end
end
