# frozen_string_literal: true

module PermissionForge
  module Admin
    # What the audit event page (audit_events/show) lays out for one event: the
    # event's data split into its before/after changes, its snapshot and
    # whatever else it carries, and which of the who/what rows have a value.
    # The template only draws it.
    #
    # @example
    #   detail = AuditEventDetail.new(event, AuditLookups.new([event]))
    #   detail.change_rows   # => [['mask_strategy', 'full', 'last4']]
    #   detail.no_data?      # => false
    class AuditEventDetail
      SNAPSHOT_ENDINGS = %w[destroyed revoked removed].freeze

      attr_reader :event, :lookups

      def initialize(event, lookups)
        @event = event
        @lookups = lookups
      end

      # The person who acted, when the actor is a user we can open.
      def actor_user
        lookups.person(event.actor_id) if event.actor_type == 'user'
      end

      def person = lookups.person(event.subject_user_id)
      def permission_set = lookups.permission_set(event.permission_set_id)

      def actor_id? = event.actor_id.present?
      def record? = event.record_type.present?
      def record_id? = event.record_id.present?
      def record_uuid? = event.record_uuid.present?
      def permission_set? = event.permission_set_id.present? || event.permission_set_uuid.present?
      def permission_set_key = event.permission_set_id || event.permission_set_uuid
      def subject_user? = event.subject_user_id.present?
      def correlation? = event.correlation_id.present?

      # [attribute, before, after] per changed attribute; a bare value (not a
      # [before, after] pair) is an "after" with no before.
      def change_rows
        return [] unless changes

        changes.map do |attribute, pair|
          before, after = pair.is_a?(Array) && pair.size == 2 ? pair : [nil, pair]
          [attribute, before, after]
        end
      end

      def changes? = !changes.nil?
      def changes_count = changes&.size.to_i
      def snapshot? = !snapshot.nil?
      def snapshot_rows = snapshot.to_a

      # The event's snapshot is of something that went away.
      def snapshot_of_removed? = event.event.end_with?(*SNAPSHOT_ENDINGS)

      def other_rows = other.to_a
      def other? = other.any?
      def no_data? = changes.nil? && snapshot.nil? && other.empty?

      private

      def data = @data ||= event.data.is_a?(Hash) ? event.data : {}
      def changes = @changes ||= (data['changes'] if data['changes'].is_a?(Hash))
      def snapshot = @snapshot ||= (data['snapshot'] if data['snapshot'].is_a?(Hash))

      def other
        @other ||= data.reject { |key, _| (key == 'changes' && changes) || (key == 'snapshot' && snapshot) }
      end
    end
  end
end
