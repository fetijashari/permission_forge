# frozen_string_literal: true

module PermissionForge
  module Admin
    # Who created and who last edited each permission record. Creation comes
    # from created_by / created_at (HasAuditTrail); the last edit from the
    # record's latest change event when the audit log has one (LastChanges),
    # else from updated_by / updated_at — an event names the real editor,
    # while updated_by keeps the previous one across an edit by nobody, an
    # HTTP Basic login or an API client. The full history is the audit log
    # (Admin::AuditLog).
    class AuditTrail
      TYPES = {
        'permission_set' => 'PermissionForge::PermissionSet',
        'resource' => 'PermissionForge::Resource',
        'field' => 'PermissionForge::ResourceField',
        'action' => 'PermissionForge::ResourceAction',
        'rule' => 'PermissionForge::PermissionSetRule',
        'assignment' => 'PermissionForge::PermissionSetUser',
        'group' => 'PermissionForge::PermissionSetGroup',
        'group_membership' => 'PermissionForge::PermissionSetGroupUser'
      }.freeze

      DAY_FILTERS = [7, 30, 90].freeze
      CSV_HEADER = ['Type', 'Record', 'Where', 'Created by', 'Created at', 'Last edited by', 'Last edited at'].freeze

      # `last_event` — the record's latest change event, or nil (no events:
      # auditing off, or the record predates the audit log).
      Entry = Struct.new(:type, :record, :last_event, keyword_init: true) do
        def created_by = record.try(:created_by)
        def updated_by = record.try(:updated_by)
        def created_at = record.created_at
        def created_by_id = record.try(:created_by_id)
        def updated_by_id = record.try(:updated_by_id)

        # When the last edit happened: the event's time when there is one.
        def updated_at = last_event ? last_event.occurred_at : record.updated_at

        # The last editor's user id as a String, or nil (not a person, or unknown).
        def editor_id
          return updated_by_id&.to_s unless last_event

          last_event.actor_id if last_event.actor_type == 'user'
        end
      end

      def self.type_of(record)
        TYPES.key(record.class.name)
      end

      # People who appear as creator/editor in the given entries.
      def self.editors(entries)
        entries.flat_map { |e| [e.created_by, e.updated_by] }.compact.uniq(&:id)
      end

      # Records a person created or last edited, grouped by type, most
      # recently edited first. `limit` caps each type (the admin page);
      # nil lists everything (the CSV export).
      # @return [Hash{String => Array<Entry>}]
      def changes_by(user_id, limit: nil)
        TYPES.each_with_object({}) do |(type, class_name), out|
          records = touched_records(class_name.constantize, user_id, limit)
          entries = entries_for(records.map { |record| [type, record] }).select { |entry| made_by?(entry, user_id) }
          out[type] = entries if entries.any?
        end
      end

      # Whether the last changes_by(limit:) read as many rows as the limit
      # for some type (more may exist), whatever it kept of them.
      def capped?
        @capped == true
      end

      # Every record belonging to a Permission Set (the set, its resources,
      # fields, actions, rules and assignments), filtered and sorted.
      # Filters (all optional): who:, type:, days:, sort: ('asc' / 'desc', default 'desc').
      # @return [Array<Entry>]
      def for_permission_set(permission_set, **filters)
        entries = apply_filters(permission_set_entries(permission_set), filters)
        sorted = entries.sort_by { |e| e.updated_at || e.created_at || Time.at(0) }
        filters[:sort].to_s == 'asc' ? sorted : sorted.reverse
      end

      # @param describe [#call] (entry) -> [type_label, record_label, where]
      # @param person [#call] (entry) -> [created by, last edited by]
      def to_csv(entries, describe:, person:)
        Csv.document([CSV_HEADER] + entries.map { |entry| csv_row(entry, describe, person) })
      end

      private

      def csv_row(entry, describe, person)
        type_label, label, where = describe.call(entry)
        created_by, edited_by = person.call(entry)
        [type_label, label, where, created_by, entry.created_at&.iso8601, edited_by, entry.updated_at&.iso8601]
      end

      # The records a person created or was stamped as editing, latest edit
      # first; notes when the limit was reached (capped?).
      def touched_records(model, user_id, limit)
        records = with_people(touched_by(model, user_id).order(updated_at: :desc).limit(limit)).to_a
        @capped = true if limit && records.size >= limit
        records
      end

      def touched_by(model, user_id)
        model.where(created_by_id: user_id).or(model.where(updated_by_id: user_id))
      end

      # Created it, or made its last edit (by the event when there is one).
      def made_by?(entry, user_id)
        entry.created_by_id.to_s == user_id.to_s || entry.editor_id == user_id.to_s
      end

      def apply_filters(entries, filters)
        type, who, days = filters.values_at(:type, :who, :days)
        entries = entries.select { |e| e.type == type } if type.present? && TYPES.key?(type)
        entries = filter_who(entries, who) if who.present?
        entries = filter_days(entries, days.to_i) if DAY_FILTERS.include?(days.to_i)
        entries
      end

      def with_people(scope)
        scope.includes(:created_by, :updated_by)
      rescue StandardError
        scope
      end

      def permission_set_entries(permission_set)
        resources = with_people(permission_set.resources).to_a
        records = [['permission_set', permission_set]] + resources.map { |r| ['resource', r] } +
                  resource_child_records(resources.map(&:id)) + permission_set_child_records(permission_set)
        entries_for(records)
      end

      def permission_set_child_records(permission_set)
        typed('rule', permission_set.permission_set_rules.includes(:resource)) +
          typed('assignment', permission_set.permission_set_users.includes(:user))
      end

      def resource_child_records(resource_ids)
        typed('field', PermissionForge::ResourceField.where(resource_id: resource_ids).includes(:resource)) +
          typed('action', PermissionForge::ResourceAction.where(resource_id: resource_ids).includes(:resource))
      end

      def typed(type, scope)
        with_people(scope).map { |record| [type, record] }
      end

      # [[type, record], ...] → entries, each with its latest change event.
      def entries_for(typed_records)
        last = LastChanges.new(typed_records.map(&:last))
        typed_records.map { |type, record| Entry.new(type: type, record: record, last_event: last.last_edit(record)) }
      end

      def filter_who(entries, who)
        entries.select { |e| e.created_by_id.to_s == who.to_s || e.editor_id == who.to_s }
      end

      def filter_days(entries, days)
        cutoff = days.days.ago
        entries.select do |e|
          time = e.updated_at || e.created_at
          time && time >= cutoff
        end
      end
    end
  end
end
