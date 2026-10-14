# frozen_string_literal: true

module PermissionForge
  module Admin
    # The name a Permission Set or group had when each event of a page
    # happened, from the label snapshots of its own events (a create, update
    # or destroy keeps the name it had then): the latest at or before the
    # event, else what its first recorded rename started from (or that
    # event's own label), else nil (the caller falls back to today's name).
    #
    # Reads a bounded slice, never the whole history: the record's events
    # inside the page's time span and its one latest event before it (two
    # plucks of four columns), plus one full event per record that has no
    # earlier event at all (for its `changes`).
    class AuditNameHistory
      Entry = Struct.new(:record_id, :occurred_at, :id, :record_label)
      COLUMNS = %i[record_id occurred_at id record_label].freeze

      # @param model [Class] PermissionSet or PermissionSetGroup
      # @param ids [Array] the record ids the page names
      # @param events [Array<AuditEvent>] the page
      def initialize(model, ids, events)
        @ids = ids.compact_blank.map(&:to_s).uniq
        @first, @last = events.filter_map(&:occurred_at).minmax
        @scope = PermissionForge::AuditEvent.where(record_type: model.base_class.name, record_id: @ids)
        @first_events = {}
      end

      # @return [String, nil]
      def name_as_of(id, event)
        return if @ids.empty? || @first.nil? || event.occurred_at.nil?

        rows = entries.fetch(id.to_s, [])
        earlier = latest_at_or_before(rows, [event.occurred_at, event.id || 0])
        return earlier.record_label.presence if earlier

        name_before(first_event(id.to_s, rows))
      end

      private

      def latest_at_or_before(rows, moment)
        rows.reverse_each.find { |row| ([row.occurred_at, row.id] <=> moment) <= 0 }
      end

      # { "id" => [Entry, ...] oldest first }
      def entries
        @entries ||= (span + latest_before_span).uniq(&:id).sort_by { |row| [row.occurred_at, row.id] }.group_by(&:record_id)
      rescue ActiveRecord::ActiveRecordError
        {}
      end

      def span = pluck(@scope.where(occurred_at: @first..@last))

      def latest_before_span
        latest = @scope.where(occurred_at: ...@first).group(:record_id).maximum(:occurred_at)
        return [] if latest.empty?

        pluck(latest.map { |id, at| @scope.where(record_id: id, occurred_at: at) }.reduce(:or))
      end

      def pluck(relation) = relation.pluck(*COLUMNS).map { |values| Entry.new(*values) }

      # The record's first recorded event (it has none at or before the
      # event asking): the first one in the span, else the first after it.
      def first_event(id, rows)
        return @first_events[id] if @first_events.key?(id)

        @first_events[id] =
          if rows.any? then PermissionForge::AuditEvent.find_by(id: rows.first.id)
          else @scope.where(record_id: id).where(occurred_at: @last..).order(:occurred_at, :id).first
          end
      rescue ActiveRecord::ActiveRecordError
        @first_events[id] = nil
      end

      def name_before(event)
        return unless event

        renamed = event.data.dig('changes', 'name')
        renamed.is_a?(Array) ? renamed.first.presence : event.record_label.presence
      end
    end
  end
end
