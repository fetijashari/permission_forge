# frozen_string_literal: true

module PermissionForge
  module Admin
    module Exports
      # The audit log export: every event the filter matches (views of the
      # log included, whatever the page hid), oldest first,
      # with every column (the JSON API's, from AuditEventSerializer) and
      # `data` as JSON. The rows are fixed when the export starts — the
      # events up to the newest one then — so the row count in the metadata
      # is the number of rows that follow, even while new events (this
      # export's own audit.exported, for one) are being written.
      class Events
        BATCH_SIZE = 1000
        KIND = 'audit_events'

        def self.columns
          PermissionForge::Api::Serializers::AuditEventSerializer.attribute_names.map(&:to_s)
        end

        # @param relation [ActiveRecord::Relation] the filtered events, in any order
        # @param filters [Hash] the filters, as written in the metadata
        # @param exported_by [Audit::Actor]
        # @param batch_size [Integer] events read per query
        # @param time_zone [String] the zone date-only filters were read in
        # @return [Document]
        def self.call(relation, filters:, exported_by: PermissionForge::Audit::Actor.current, now: Time.current, # rubocop:disable Metrics/ParameterLists
                      batch_size: BATCH_SIZE, time_zone: AuditLogDays.zone_name)
          events = snapshot(relation.unscope(:order))
          # An export is evidence: views of the log are always in it, and it says so.
          meta = Exports.meta(KIND, exported_by: exported_by, filters: filters.to_h.merge('include_views' => true),
                                    row_count: events.count, now: now, time_zone: time_zone)
          Document.new(columns: columns, meta: meta, rows: lambda { |&row|
            events.find_each(batch_size: batch_size) { |event| row.call(serialize(event)) }
          })
        end

        def self.snapshot(events)
          newest = events.maximum(:id)
          newest ? events.where(id: ..newest) : events.none
        end

        def self.serialize(event)
          PermissionForge::Api::Serializers::AuditEventSerializer.new(event).as_json.transform_keys(&:to_s)
        end

        private_class_method :snapshot, :serialize
      end
    end
  end
end
