# frozen_string_literal: true

module PermissionForge
  module Admin
    # The people, Permission Sets and Permission Set Groups a page of audit
    # events names, loaded once for the page (one query per kind) so every
    # row can say "Ana gave Bo the Permission Set Sales". A record that is
    # gone is simply not found: the event's own label snapshots stand in.
    #
    # A set or group is named as it was when the event happened
    # (#permission_set_name, #group_name): the label of its own latest event
    # at or before that moment (a create, update or destroy keeps the name it
    # had then), else the name its earliest later rename started from, else
    # its name today (AuditNameHistory; no new column, a bounded read).
    class AuditLookups
      GROUP_KEYS = %w[permission_set_group_id].freeze

      # @param events [Array<AuditEvent>]
      def initialize(events, configuration: PermissionForge.configuration)
        @events = Array(events)
        @configuration = configuration
      end

      # @param id [String, Integer, nil] a user id
      # @return [Object, nil] the host user
      def person(id)
        people[id.to_s] if id.present?
      end

      # @return [PermissionForge::PermissionSet, nil]
      def permission_set(id)
        permission_sets[id.to_i] if id.present?
      end

      # The Permission Set Group of a membership event (from its data).
      # @return [PermissionForge::PermissionSetGroup, nil]
      def group(event)
        id = self.class.group_id(event)
        groups[id.to_i] if id
      end

      # The Permission Set's name when `event` happened (nil: unknown).
      # @return [String, nil]
      def permission_set_name(event)
        id = event.permission_set_id
        return if id.blank?

        set_history.name_as_of(id, event) || permission_set(id)&.name
      end

      # The name of a membership event's group when the event happened.
      # @return [String, nil]
      def group_name(event)
        id = self.class.group_id(event)
        return unless id

        group_history.name_as_of(id, event) || groups[id.to_i]&.name
      end

      def self.group_id(event)
        data = event.data || {}
        snapshot = data['snapshot'].is_a?(Hash) ? data['snapshot'] : {}
        changes = data['changes'].is_a?(Hash) ? data['changes'] : {}
        GROUP_KEYS.each do |key|
          value = snapshot[key] || Array(changes[key]).last
          return value if value.present?
        end
        nil
      end

      private

      def people
        @people ||= begin
          ids = @events.flat_map { |e| [e.subject_user_id, (e.actor_id if e.actor_type == 'user')] }.compact_blank.uniq
          ids.empty? ? {} : @configuration.user_model.where(id: ids).index_by { |user| user.id.to_s }
        rescue StandardError
          {}
        end
      end

      def permission_sets
        @permission_sets ||= find_by_ids(PermissionForge::PermissionSet, @events.map(&:permission_set_id))
      end

      def groups
        @groups ||= find_by_ids(PermissionForge::PermissionSetGroup, @events.map { |e| self.class.group_id(e) })
      end

      def find_by_ids(model, ids)
        ids = ids.compact.map(&:to_i).uniq
        ids.empty? ? {} : model.where(id: ids).index_by(&:id)
      end

      def set_history
        @set_history ||= AuditNameHistory.new(PermissionForge::PermissionSet, @events.map(&:permission_set_id), @events)
      end

      def group_history
        @group_history ||= AuditNameHistory.new(PermissionForge::PermissionSetGroup,
                                                @events.map { |e| self.class.group_id(e) }, @events)
      end
    end
  end
end
