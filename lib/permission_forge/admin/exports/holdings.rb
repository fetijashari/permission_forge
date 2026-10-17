# frozen_string_literal: true

module PermissionForge
  module Admin
    module Exports
      # "Who holds what": every assignment as it stands — the person, the
      # Permission Set, when and by whom it was granted, when it ends, when
      # and by whom it was last reviewed, and the reason of its last change.
      # Granted by is the actor of the assignment.granted event when the
      # audit log has one — named as the admin names it (Admin::ActorLabel:
      # a code such as an API client nobody named in the export's language;
      # the actor's kind and id stay as stored, and the events export keeps
      # the stored label) — else the created_by column.
      #
      # The rows are read while the file is written (batches of BATCH_SIZE,
      # the way the events export does), never all at once. `row_count` in the
      # metadata is a COUNT taken when the export starts, on the assignments up
      # to the newest id then. Assignments are changed and removed, not only
      # added: one removed while the file is written is missing from it
      # (`row_count` can then exceed the rows), and each row shows its
      # assignment as it was when its batch was read. The person lookups run
      # per batch, in the tenant and with the record rules suspended as in the
      # action (AuditEventsController#pf_stream).
      class Holdings
        BATCH_SIZE = 500
        KIND = 'holdings'
        COLUMNS = %w[assignment_id assignment_uuid person_id person permission_set_id permission_set_uuid permission_set
                     muting set_active granted_at granted_by_type granted_by_id granted_by expires_at expired
                     reviewed_at reviewed_by_id reviewed_by reason].freeze

        # @param exported_by [Audit::Actor]
        # @param batch_size [Integer] assignments read per query
        # @return [Document]
        def self.call(exported_by: PermissionForge::Audit::Actor.current, now: Time.current, batch_size: BATCH_SIZE)
          new(now, batch_size).document(exported_by)
        end

        def initialize(now, batch_size = BATCH_SIZE)
          @now = now
          @batch_size = batch_size
        end

        def document(exported_by)
          assignments = snapshot
          meta = Exports.meta(KIND, exported_by: exported_by, filters: {}, row_count: assignments.count, now: @now)
          Document.new(columns: COLUMNS, meta: meta, rows: ->(&row) { each_row(assignments, &row) })
        end

        private

        # The assignments as they stand now: up to the newest id.
        def snapshot
          assignments = PermissionForge::PermissionSetUser.includes(:permission_set, :user)
          newest = assignments.maximum(:id)
          newest ? assignments.where(id: ..newest) : assignments.none
        end

        # Outside the query cache: it would keep every batch's results for the request.
        def each_row(assignments, &)
          ActiveRecord::Base.uncached { each_batch(assignments, &) }
        end

        def each_batch(assignments)
          assignments.find_in_batches(batch_size: @batch_size) do |batch|
            granted = LastChanges.creations(batch)
            people = people_by_id(batch)
            batch.each { |assignment| yield row(assignment, granted[assignment], people) }
          end
        end

        def row(assignment, grant_event, people)
          set = assignment.permission_set
          person(assignment).merge(permission_set_columns(set)).merge(
            'granted_at' => assignment.created_at, **granted_by(assignment, grant_event, people),
            'expires_at' => assignment.expires_at, 'expired' => assignment.expired?,
            **reviewed(assignment, people), 'reason' => assignment.try(:reason)
          )
        end

        def person(assignment)
          { 'assignment_id' => assignment.id, 'assignment_uuid' => assignment.try(:uuid), 'person_id' => assignment.user_id,
            'person' => label(assignment.user) }
        end

        def permission_set_columns(set)
          { 'permission_set_id' => set&.id, 'permission_set_uuid' => set&.uuid, 'permission_set' => set&.name,
            'muting' => set&.is_muting, 'set_active' => set&.is_active }
        end

        def granted_by(assignment, event, people)
          if event
            return { 'granted_by_type' => event.actor_type, 'granted_by_id' => event.actor_id,
                     'granted_by' => ActorLabel.for(event) }
          end

          id = assignment.try(:created_by_id)
          { 'granted_by_type' => (id ? 'user' : nil), 'granted_by_id' => id, 'granted_by' => label(people[id.to_s]) }
        end

        def reviewed(assignment, people)
          id = assignment.try(:reviewed_by_id)
          { 'reviewed_at' => assignment.try(:reviewed_at), 'reviewed_by_id' => id, 'reviewed_by' => label(people[id.to_s]) }
        end

        # The creators and reviewers of a batch, by id (String).
        def people_by_id(batch)
          ids = batch.flat_map { |assignment| [assignment.try(:created_by_id), assignment.try(:reviewed_by_id)] }.compact.uniq
          return {} if ids.empty?

          PermissionForge.configuration.user_model.where(id: ids).index_by { |user| user.id.to_s }
        rescue StandardError
          {}
        end

        def label(user)
          PersonLabel.new(user).name if user
        end
      end
    end
  end
end
