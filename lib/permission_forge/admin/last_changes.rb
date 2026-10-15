# frozen_string_literal: true

require 'active_support/core_ext/numeric/time' # UNSEEN_AFTER, read as this file loads

module PermissionForge
  module Admin
    # The latest recorded change event of each of a list of records: who
    # really made the last edit, and when. `updated_by` alone cannot say —
    # an edit by nobody, by an HTTP Basic login or by an API client keeps the
    # previous editor — so wherever the admin shows "last edited by", an
    # event wins over the columns (see AuditTrail::Entry and the footer).
    # The same holds for "created by" (.creations).
    #
    # Two queries per record type and slice: the newest event id per record
    # (the ids grow with every insert), then those events.
    class LastChanges
      SLICE = 500

      # The creation event of each record — its model's `audit_event_name(:create)`:
      # permission_set.created, assignment.granted, group_membership.added, ... —
      # read with #[]. Who created a record is that event's actor wherever the
      # admin shows it (AuditHelper#pf_audit_creator): an HTTP Basic login or an
      # API client stamps no created_by, and the audit log still names them.
      #
      # @param records [Array<ActiveRecord::Base>] permission records
      # @return [LastChanges]
      def self.creations(records)
        records = Array(records).compact
        new(records, events: records.map { |record| record.class.audit_event_name(:create) }.uniq)
      end

      # @param records [Array<ActiveRecord::Base>] permission records
      # @param events [Array<String>, nil] only these change events (e.g.
      #   %w[assignment.granted] — who granted it); nil: any change event
      def initialize(records, events: nil)
        @records = Array(records).compact
        @events = events
      end

      # Edits this much later than the last event are edits the log did not see.
      UNSEEN_AFTER = 1.second

      # @return [AuditEvent, nil] the latest (matching) change event of the record
      def [](record)
        index[key(record.class.base_class.name, record.id)]
      end

      # The latest change event when it is the record's last edit; nil when
      # the record was edited after it (updated_at more than UNSEEN_AFTER
      # later — an edit made while auditing was off): the columns are newer.
      #
      # @return [AuditEvent, nil]
      def last_edit(record)
        event = self[record]
        return nil unless event

        updated = record.try(:updated_at)
        updated && updated > event.occurred_at + UNSEEN_AFTER ? nil : event
      end

      # Whether the record is one of those this lookup was built for.
      def covers?(record)
        @keys ||= @records.to_set { |candidate| key(candidate.class.base_class.name, candidate.id) }
        @keys.include?(key(record.class.base_class.name, record.id))
      end

      private

      def key(type, id)
        "#{type}##{id}"
      end

      def index
        @index ||= available? ? load_index : {}
      end

      def available?
        @records.any? && PermissionForge::Audit.enabled?
      rescue StandardError
        false
      end

      def load_index
        ids_by_type.each_with_object({}) do |(type, ids), out|
          ids.each_slice(SLICE) { |slice| index_latest(out, type, slice) }
        end
      end

      def index_latest(index, type, ids)
        latest(type, ids).each { |event| index[key(type, event.record_id)] = event }
      end

      # { record type => [ids as Strings] }
      def ids_by_type
        @records.group_by { |record| record.class.base_class.name }
                .transform_values { |records| records.map { |record| record.id.to_s }.uniq }
      end

      def latest(type, ids)
        events = PermissionForge::AuditEvent
        matching = events.where(category: 'change', record_type: type, record_id: ids)
        matching = matching.where(event: @events) if @events
        newest = matching.group(:record_id).select(events.arel_table[:id].maximum)
        events.where(id: newest).to_a
      end
    end
  end
end
