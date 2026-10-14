# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # Recorded events are evidence: nothing a client sends — a route, a verb,
    # a parameter — writes or rewrites one, the model refuses every update
    # and delete, and the only code that changes existing events is the
    # retention purge (old rows) and the erasure scrub (the erased person's
    # name snapshots).
    class ImmutabilityTest < ActionDispatch::IntegrationTest
      include IntegrationSupport

      WRITE_VERBS = %i[post patch put delete].freeze
      COLUMNS = %w[uuid occurred_at event category actor_type actor_id actor_label source record_type record_id record_uuid
                   record_label permission_set_id permission_set_uuid subject_user_id data reason request_id ip
                   correlation_id created_at].freeze

      setup do
        @admin = create_user(name: ADMIN_NAME)
        @ana = create_user(name: 'Ana Krasniqi')
        @set = create_permission_set(name: 'Sales rep')
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
        sign_in(@admin)
        @event = assert_audit_event('assignment.granted', record_id: @assignment.id.to_s)
      end

      test 'no route of the engine writes to the audit log' do
        writers = IntegrationSupport.engine_write_routes.select { |_verb, path, endpoint| "#{path} #{endpoint}".include?('audit') }

        assert_empty(writers.map { |verb, path, _| "#{verb} #{path}" })
      end

      test 'no verb but GET reaches the audit log, in the API or the admin UI, also with a method override' do
        paths = ['/api/audit_events', "/api/audit_events/#{@event.uuid}", "/api/audit_events/#{@event.id}", '/audit', "/audit/#{@event.uuid}"]
        before = @event.attributes

        paths.product(WRITE_VERBS).each do |path, verb|
          assert_raises(ActionController::RoutingError, "#{verb.upcase} #{path}") do
            send(verb, "#{ROOT}#{path}", params: { audit_event: { actor_label: 'Mallory' }, event: 'x' }, as: :json)
          end
        end
        assert_raises(ActionController::RoutingError) { post "#{ROOT}/api/audit_events/#{@event.uuid}", params: { _method: 'delete' } }
        assert_equal before, @event.reload.attributes
      end

      test 'request parameters and headers cannot set the columns of the events a request writes' do
        forged = { actor_id: '999', actor_type: 'system', actor_label: 'Mallory', source: 'console', correlation_id: 'forged',
                   occurred_at: '2001-01-01', event: 'audit.purged', category: 'system', ip: '6.6.6.6', subject_user_id: '1',
                   audit_event: { actor_label: 'Mallory' } }
        headers = { 'X-PF-Actor' => 'Mallory', 'X-Actor-Id' => '999' }

        patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: forged.merge(pf: { set: { description: 'Edited' } }), headers: headers

        event = assert_audit_event('permission_set.updated', record_id: @set.id.to_s)
        assert_equal ['user', @admin.id.to_s, ADMIN_NAME, 'admin_ui', 'change'],
                     event.attributes.values_at(*%w[actor_type actor_id actor_label source category])
        assert_not_equal 'forged', event.correlation_id
        assert_operator event.occurred_at, :>, 1.minute.ago
        assert_not_equal '6.6.6.6', event.ip
        assert_nil event.subject_user_id
      end

      test 'a recorded event refuses every update and delete the model offers' do
        writes = {
          'save' => ->(e) { e.tap { e.actor_label = 'x' }.save! },
          'update' => ->(e) { e.update!(actor_label: 'x') },
          'update_attribute' => ->(e) { e.update_attribute(:actor_label, 'x') },
          'update_column' => ->(e) { e.update_column(:actor_label, 'x') },
          'update_columns' => ->(e) { e.update_columns(actor_label: 'x') },
          'touch' => lambda(&:touch),
          'increment!' => ->(e) { e.increment!(:permission_set_id) },
          'destroy' => lambda(&:destroy!),
          'delete' => lambda(&:delete),
          'Class.update' => ->(e) { AuditEvent.update(e.id, actor_label: 'x') },
          'Class.destroy' => ->(e) { AuditEvent.destroy(e.id) },
          'upsert' => ->(e) { AuditEvent.upsert(e.attributes.merge('actor_label' => 'x')) },
          'upsert_all' => ->(e) { AuditEvent.upsert_all([e.attributes.merge('actor_label' => 'x')]) },
          'destroy_all' => ->(e) { AuditEvent.where(id: e.id).destroy_all }
        }
        before = @event.attributes

        writes.each do |name, write|
          assert_raises(ActiveRecord::ReadOnlyRecord, name) { write.call(AuditEvent.find(@event.id)) }
        end
        assert_equal before, @event.reload.attributes
      end

      test 'only the erasure scrub and the retention purge change recorded events' do
        bo = create_user(name: 'Bo Berisha')
        old = Audit.record('report.generated', data: { 'task' => 'long ago' }, occurred_at: 3.years.ago)
        patch "#{ROOT}/permission_sets/#{@set.id}/apply", params: { pf: { set: { description: 'Edited' } } }
        post "#{ROOT}/assignments", params: { user_id: bo.id, set_ids: [@set.id], expiry: 'never' }
        delete "#{ROOT}/assignments/#{@assignment.id}"
        before = snapshot_events

        post "#{ROOT}/people/#{bo.id}/erasure", params: { confirmation: 'Bo Berisha' }
        Services::AuditEventPurger.call(older_than: 1.year, actor: @admin)

        after = snapshot_events
        assert_not after.key?(old.id), 'the purge removes what is past the retention period'
        (before.keys - [old.id]).each { |id| assert_only_scrubbed(before.fetch(id), after.fetch(id), bo) }
      end

      private

      def snapshot_events
        AuditEvent.unscoped.order(:id).to_h { |event| [event.id, event.attributes.slice(*COLUMNS)] }
      end

      # Unchanged, except the name snapshots of an event about the erased person.
      def assert_only_scrubbed(before, after, erased)
        changed = before.keys.reject { |column| before[column] == after[column] }
        return assert_empty(changed, "event #{before['event']} #{before['uuid']} was changed") unless before['subject_user_id'] == erased.id.to_s

        assert_empty changed - %w[record_label actor_label], "only name snapshots of #{before['event']} may be cleared"
        assert_nil after['record_label']
      end
    end
  end
end
