# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  # Change events written by the 8 permission models from inside their own
  # transaction (Concerns::RecordsAuditEvents).
  class RecordsAuditEventsTest < ActiveSupport::TestCase
    include PermissionForge::Tenancy::TenancyTestHelper

    def with_failing_store
      store = PermissionForge::AuditEvent.method(:store!)
      replace_singleton_method(PermissionForge::AuditEvent, :store!) { |*| raise ActiveRecord::StatementInvalid, 'disk full' }
      yield
    ensure
      replace_singleton_method(PermissionForge::AuditEvent, :store!, store)
    end

    def events_named(name) = PermissionForge::AuditEvent.where(event: name).order(:id)

    def fixtures_for_all_models
      set = create_permission_set(name: 'Ops')
      group = create_permission_set_group(name: 'Staff')
      resource = create_resource(permission_set: set)
      user = create_user(name: 'Holder')
      {
        'permission_set' => [set, { name: 'Ops renamed' }],
        'permission_set_group' => [group, { name: 'Staff renamed' }],
        'resource' => [resource, { description: 'Customers of the account' }],
        'resource_field' => [create_resource_field(resource: resource), { label: 'Full name' }],
        'resource_action' => [create_resource_action(resource: resource), { label: 'Export CSV' }],
        'permission_set_rule' => [create_permission_set_rule(permission_set: set, resource: resource), { name: 'Own rows' }],
        'assignment' => [create_permission_set_user(user: user, permission_set: set), { expires_at: 1.month.from_now }],
        'group_membership' => [PermissionForge::PermissionSetGroupUser.create!(user: user, permission_set_group: group),
                               { reason: 'joined the team' }]
      }
    end

    VERBS = {
      'permission_set' => %w[created updated destroyed], 'permission_set_group' => %w[created updated destroyed],
      'resource' => %w[created updated destroyed], 'resource_field' => %w[created updated destroyed],
      'resource_action' => %w[created updated destroyed], 'permission_set_rule' => %w[created updated destroyed],
      'assignment' => %w[granted changed revoked], 'group_membership' => %w[added changed removed]
    }.freeze

    # --- one event per create, update and destroy on each model ------------------------

    test 'every model writes one event per create, update and destroy' do
      fixtures_for_all_models.each do |key, (record, update)|
        created, updated, destroyed = VERBS.fetch(key).map { |verb| "#{key}.#{verb}" }
        assert_equal 1, audit_events_for(record).where(event: created).count, "#{key}: one created event"

        record.update!(update)
        assert_equal 1, audit_events_for(record).where(event: updated).count, "#{key}: one updated event"

        record.destroy!
        assert_equal 1, audit_events_for(record).where(event: destroyed).count, "#{key}: one destroyed event"
        assert_equal 3, audit_events_for(record).count, "#{key}: nothing else"
      end
    end

    test 'the create event carries a snapshot and the record reference' do
      Current.user = create_user(name: 'Admin')
      set = create_permission_set(name: 'Ops')
      event = assert_audit_event('permission_set.created', record_type: 'PermissionForge::PermissionSet',
                                                           record_id: set.id.to_s, record_uuid: set.uuid, record_label: 'Ops',
                                                           permission_set_id: set.id, permission_set_uuid: set.uuid,
                                                           actor_type: 'user', actor_id: Current.user.id.to_s, actor_label: 'Admin')
      assert_equal 'Ops', event.data.dig('snapshot', 'name')
      assert_equal set.id, event.data.dig('snapshot', 'id')
      assert_equal 'change', event.category
    end

    test 'the update event carries the changes without the bookkeeping columns' do
      PermissionForge.configuration.audit_trail_enabled = true
      Current.user = create_user(name: 'Admin')
      set = create_permission_set(name: 'Ops', description: 'old')
      travel 1.minute
      set.update!(name: 'Ops 2', description: 'new')
      event = assert_audit_event('permission_set.updated', record_id: set.id.to_s)
      assert_equal({ 'name' => ['Ops', 'Ops 2'], 'description' => %w[old new] }, event.data['changes'])
      assert_nil event.data['snapshot']
    ensure
      PermissionForge.configuration.audit_trail_enabled = false
    end

    test 'saving a record with nothing to say writes nothing' do
      set = create_permission_set(name: 'Ops')
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        set.save!
        set.update!(name: 'Ops')
      end
    end

    test 'an update that only touches bookkeeping columns writes nothing' do
      set = create_permission_set(name: 'Ops')
      editor = create_user
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        set.update!(updated_by_id: editor.id)
      end
    end

    test 'destroying an instance whose row is already gone writes no second event' do
      set = create_permission_set(name: 'Ops')
      resource = create_resource(permission_set: set)
      set.destroy!
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        resource.destroy!
        set.destroy!
      end
      assert_equal 1, audit_events_for(resource).where(event: 'resource.destroyed').count
    end

    test 'the destroy event carries a full snapshot' do
      field = create_resource_field(resource: create_resource(permission_set: create_permission_set), name: 'email',
                                    mask_access: true, mask_strategy: 'email')
      field.destroy!
      event = assert_audit_event('resource_field.destroyed', record_id: field.id.to_s)
      snapshot = event.data['snapshot']
      assert_equal 'email', snapshot['name']
      assert_equal true, snapshot['mask_access']
      assert_equal 'email', snapshot['mask_strategy']
      assert_equal field.resource_id, snapshot['resource_id']
      assert_equal field.uuid, snapshot['uuid']
      assert snapshot.key?('created_at')
    end

    # --- what the reference columns hold per model --------------------------------------

    test 'a field names its resource, its permission set and its tenant' do
      set = create_permission_set(name: 'Ops')
      resource = create_resource(permission_set: set, name: 'Customer')
      field = create_resource_field(resource: resource, name: 'email')
      assert_audit_event('resource_field.created', record_label: 'Customer.email', permission_set_id: set.id,
                                                   permission_set_uuid: set.uuid, account_id: DEFAULT_TEST_ACCOUNT.id,
                                                   subject_user_id: nil)
      action = create_resource_action(resource: resource, name: 'export')
      assert_audit_event('resource_action.created', record_label: 'Customer.export', permission_set_id: set.id,
                                                    record_id: action.id.to_s)
      assert_audit_event('resource.created', record_label: 'Customer', permission_set_id: set.id, record_id: resource.id.to_s)
      assert_equal field.id.to_s, audit_events_for(field).first.record_id
    end

    test 'a rule names its permission set' do
      set = create_permission_set
      rule = create_permission_set_rule(permission_set: set, resource: create_resource(permission_set: set), name: 'Own')
      assert_audit_event('permission_set_rule.created', record_label: 'Own', permission_set_id: set.id,
                                                        permission_set_uuid: set.uuid, record_id: rule.id.to_s)
    end

    test 'an assignment names the subject, the set and the person' do
      user = create_user(name: 'Holder')
      set = create_permission_set(name: 'Ops')
      assignment = create_permission_set_user(user: user, permission_set: set, expires_at: nil)
      event = assert_audit_event('assignment.granted', subject_user_id: user.id.to_s, permission_set_id: set.id,
                                                       permission_set_uuid: set.uuid, record_label: 'Holder',
                                                       record_id: assignment.id.to_s)
      assert_nil event.data.dig('snapshot', 'expires_at')

      assignment.update!(expires_at: Time.utc(2027, 1, 1))
      changed = assert_audit_event('assignment.changed', subject_user_id: user.id.to_s)
      assert_equal [nil, '2027-01-01T00:00:00.000Z'], changed.data.dig('changes', 'expires_at')

      assignment.destroy!
      revoked = assert_audit_event('assignment.revoked', subject_user_id: user.id.to_s, permission_set_id: set.id)
      assert_equal user.id, revoked.data.dig('snapshot', 'user_id')
    end

    test 'an assignment built from ids only still names the subject' do
      user = create_user(name: 'Holder')
      set = create_permission_set
      PermissionForge::PermissionSetUser.create!(user_id: user.id, permission_set_id: set.id)
      event = assert_audit_event('assignment.granted', subject_user_id: user.id.to_s, permission_set_id: set.id)
      assert_equal 'Holder', event.record_label
    end

    test 'a group membership names the subject and no permission set' do
      user = create_user(name: 'Member')
      group = create_permission_set_group(name: 'Staff')
      membership = PermissionForge::PermissionSetGroupUser.create!(user: user, permission_set_group: group)
      assert_audit_event('group_membership.added', subject_user_id: user.id.to_s, permission_set_id: nil,
                                                   permission_set_uuid: nil, record_label: 'Member',
                                                   record_id: membership.id.to_s)
      membership.destroy!
      assert_audit_event('group_membership.removed', subject_user_id: user.id.to_s)
    end

    test 'a group names itself and no permission set' do
      group = create_permission_set_group(name: 'Staff')
      assert_audit_event('permission_set_group.created', record_label: 'Staff', permission_set_id: nil, subject_user_id: nil,
                                                         record_uuid: group.uuid)
    end

    # --- correlation ------------------------------------------------------------------

    test 'deleting a set yields one event per cascaded child, all with one correlation id' do
      set = create_permission_set(name: 'Ops')
      resource = create_resource(permission_set: set)
      field = create_resource_field(resource: resource)
      action = create_resource_action(resource: resource)
      rule = create_permission_set_rule(permission_set: set, resource: resource)
      assignment = create_permission_set_user(user: create_user, permission_set: set)
      PermissionForge::AuditEvent.delete_all

      set.destroy!

      destroyed = PermissionForge::AuditEvent.order(:id).to_a
      assert_equal %w[resource_field.destroyed resource_action.destroyed permission_set_rule.destroyed resource.destroyed
                      assignment.revoked permission_set.destroyed].sort, destroyed.map(&:event).sort
      assert_equal [set, resource, field, action, rule, assignment].map { |r| r.id.to_s }.sort, destroyed.map(&:record_id).sort
      assert_equal 1, destroyed.map(&:correlation_id).uniq.size
      assert_not_nil destroyed.first.correlation_id
      assert destroyed.all? { |e| e.permission_set_id == set.id }, 'every child names the set'
    end

    test 'two separate saves get two correlation ids' do
      a = create_permission_set
      b = create_permission_set
      assert_not_equal audit_events_for(a).first.correlation_id, audit_events_for(b).first.correlation_id
    end

    test 'saves inside one transaction or one correlate block share a correlation id' do
      ids = ActiveRecord::Base.transaction do
        [create_permission_set, create_permission_set_group].map { |r| audit_events_for(r).first.correlation_id }
      end
      assert_equal 1, ids.uniq.size

      block_ids = Audit.correlate('review-7') do
        [create_permission_set, create_permission_set].map { |r| audit_events_for(r).first.correlation_id }
      end
      assert_equal ['review-7'], block_ids.uniq
    end

    # --- atomicity --------------------------------------------------------------------

    test 'a rollback leaves no event' do
      ActiveRecord::Base.transaction do
        create_permission_set(name: 'Gone')
        raise ActiveRecord::Rollback
      end
      assert_equal 0, events_named('permission_set.created').count
    end

    test 'a failing event write rolls the change back under the default strategy' do
      set = create_permission_set(name: 'Ops')
      with_failing_store do
        assert_raises(Audit::EventNotRecordedError) { create_permission_set(name: 'Never') }
        assert_raises(Audit::EventNotRecordedError) { set.update!(name: 'Never') }
        assert_raises(Audit::EventNotRecordedError) { set.destroy! }
      end
      assert_nil PermissionForge::PermissionSet.find_by(name: 'Never')
      assert_equal 'Ops', set.reload.name
      assert PermissionForge::PermissionSet.exists?(set.id)
    end

    test 'under :report a failing event write lets the change through and reports' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      reported = []
      Rails.error.subscribe(reporter = Class.new { define_method(:report) { |error, **| reported << error } }.new)
      set = nil
      with_failing_store do
        set = create_permission_set(name: 'Through')
      end
      assert set.persisted?
      assert_equal 1, reported.size
    ensure
      Rails.error.unsubscribe(reporter)
    end

    test 'a requires_new savepoint that rolls back loses its events only' do
      kept = nil
      ActiveRecord::Base.transaction do
        kept = create_permission_set(name: 'Kept')
        ActiveRecord::Base.transaction(requires_new: true) do
          create_permission_set(name: 'Lost')
          raise ActiveRecord::Rollback
        end
      end
      assert_equal 1, audit_events_for(kept).count
      assert_equal 0, PermissionForge::AuditEvent.where("data LIKE '%Lost%'").count
    end

    test 'a destroy inside a rolled-back outer transaction leaves the record and no event' do
      set = create_permission_set(name: 'Ops')
      assert_no_difference -> { PermissionForge::AuditEvent.unscoped.count } do
        ActiveRecord::Base.transaction do
          set.destroy!
          raise ActiveRecord::Rollback
        end
      end
      assert PermissionForge::PermissionSet.exists?(set.id)
      assert_empty audit_events_for(set).where(event: 'permission_set.destroyed')
    end

    test 'nested transactions publish the change events once, after the outermost commit' do
      received = []
      subscriber = ActiveSupport::Notifications.subscribe('permission_set.created.permission_forge') { |e| received << e.payload }
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) { create_permission_set }
        assert_empty received
      end
      assert_equal 1, received.size
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # --- paths that skip callbacks ----------------------------------------------------

    test 'touch, update_columns, update_all and delete_all write no event (they run no callbacks)' do
      set = create_permission_set(name: 'Ops')
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        set.touch
        set.update_columns(name: 'Quiet')
        PermissionForge::PermissionSet.where(id: set.id).update_all(name: 'Quieter')
        PermissionForge::PermissionSet.where(id: set.id).delete_all
      end
    end

    # --- switches ---------------------------------------------------------------------

    test 'with audit_events = false the models write nothing and still work' do
      PermissionForge.configuration.audit_events = false
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        set = create_permission_set(name: 'Silent')
        set.update!(name: 'Still silent')
        set.destroy!
      end
    end

    # --- tenancy ----------------------------------------------------------------------

    test 'events are written in the tenant of the record' do
      other = Account.create!(name: 'Other')
      set = nil
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        set = within(other) { create_permission_set(name: 'Theirs') }
      end
      within(other) do
        event = assert_audit_event('permission_set.created', record_id: set.id.to_s)
        assert_equal other.id, event.account_id
      end
    end

    test 'a record saved with no ambient tenant still writes its event in its own tenant' do
      set = create_permission_set(name: 'Mine')
      PermissionForge::AuditEvent.delete_all
      within(nil) do
        assert_nil ActsAsTenant.current_tenant
        set.update!(name: 'Renamed from a job')
        untenanted = ActsAsTenant.without_tenant { PermissionForge::AuditEvent.where(account_id: nil).count }
        assert_equal 0, untenanted
      end
      event = assert_audit_event('permission_set.updated', record_id: set.id.to_s)
      assert_equal DEFAULT_TEST_ACCOUNT.id, event.account_id
    end

    # --- associations are left as they were ------------------------------------------

    # (Saved without validation: the belongs_to presence check would load the
    # association itself, which is Rails' doing, not the event's.)
    test 'looking up the person for the label does not load the association' do
      holder = create_user(name: 'Holder')
      set = create_permission_set
      assignment = PermissionForge::PermissionSetUser.find(create_permission_set_user(user: holder, permission_set: set).id)
      assignment.expires_at = 3.days.from_now
      assignment.save!(validate: false)
      assert_not assignment.association(:user).loaded?
      assert_equal 'Holder', assert_audit_event('assignment.changed', record_id: assignment.id.to_s).record_label
      field = PermissionForge::ResourceField.find(create_resource_field(resource: create_resource(permission_set: set)).id)
      field.label = 'Renamed'
      field.save!(validate: false)
      assert_not field.association(:resource).loaded?
      assert_equal 'Customer.name', assert_audit_event('resource_field.updated', record_id: field.id.to_s).record_label
      assert_nil field.instance_variable_get(:@pf_audit_lookups)
    end

    test 'a person whose row is gone leaves the label empty and the association untouched' do
      holder = create_user(name: 'Gone soon')
      set = create_permission_set
      assignment = PermissionForge::PermissionSetUser.find(create_permission_set_user(user: holder, permission_set: set).id)
      User.where(id: holder.id).delete_all
      assignment.expires_at = 3.days.from_now
      assignment.save!(validate: false)
      assert_nil assert_audit_event('assignment.changed', record_id: assignment.id.to_s).record_label
      assert_not assignment.association(:user).loaded?
      assert_nil assignment.user
    end

    # --- audit_as: the row's own event under another name ----------------------------

    test 'audit_as renames and enriches the record events inside the block, then is restored' do
      assignment = create_permission_set_user(user: create_user(name: 'Holder'), permission_set: create_permission_set)
      reviewer = create_user(name: 'Reviewer')
      result = assignment.audit_as('assignment.reviewed', data: { 'decision' => 'keep' }, reason: 'quarterly review') do
        assignment.update!(reviewed_at: Time.current, reviewed_by_id: reviewer.id)
        :done
      end
      assert_equal :done, result
      event = assert_audit_event('assignment.reviewed', record_id: assignment.id.to_s, reason: 'quarterly review')
      assert_equal 'keep', event.data['decision']
      assert event.data['changes'].key?('reviewed_at')
      assert_equal 'Holder', event.record_label
      assert_equal 0, audit_events_for(assignment).where(event: 'assignment.changed').count

      assignment.update!(expires_at: 1.day.from_now)
      assert_audit_event('assignment.changed', record_id: assignment.id.to_s)
    end

    test 'audit_as applies to the record it was called on, only to its update, and is restored on raise' do
      set = create_permission_set(name: 'Ops')
      assignment = create_permission_set_user(user: create_user, permission_set: set)
      other = create_permission_set_user(user: create_user, permission_set: set)
      assignment.audit_as('assignment.reviewed', data: { 'decision' => 'keep' }) do
        assignment.update!(reviewed_at: Time.current)
        other.update!(reviewed_at: Time.current)
      end
      assert_audit_event('assignment.reviewed', record_id: assignment.id.to_s)
      assert_audit_event('assignment.changed', record_id: other.id.to_s)

      assert_raises(RuntimeError) { assignment.audit_as('assignment.reviewed') { raise 'boom' } }
      assignment.update!(expires_at: 2.days.from_now)
      assert_audit_event('assignment.changed', record_id: assignment.id.to_s)

      # a destroy inside the block is not a review: it keeps its own event
      assignment.audit_as('assignment.reviewed', reason: 'left') { assignment.destroy! }
      event = assert_audit_event('assignment.revoked', record_id: assignment.id.to_s)
      assert event.data.key?('snapshot')
      assert_nil event.data['decision']
      assert_nil event.reason
    end

    test 'audit_as takes a registered change event only' do
      set = create_permission_set
      assert_raises(Audit::EventCatalog::UnknownEventError) { set.audit_as('permission_set.renamed') { nil } }
      assert_raises(ArgumentError) { set.audit_as('access.denied') { nil } }
      assert_raises(ArgumentError) { set.audit_as('report.generated') { nil } }
    end

    test 'audit_as renames only to the events listed for the model (A2)' do
      set = create_permission_set
      assignment = create_permission_set_user(user: create_user, permission_set: set)
      membership = PermissionForge::PermissionSetGroupUser.create!(user: create_user, permission_set_group: create_permission_set_group)
      field = create_resource_field(resource: create_resource(permission_set: set), name: 'email')

      assert_raises(ArgumentError) { set.audit_as('permission_set.cloned') { nil } }
      assert_raises(ArgumentError) { set.audit_as('resource.destroyed') { nil } }
      assert_raises(ArgumentError) { assignment.audit_as('assignment.revoked') { nil } }
      assert_raises(ArgumentError) { assignment.audit_as('field.sensitive_acknowledged') { nil } }
      assert_raises(ArgumentError) { membership.audit_as('group_membership.removed') { nil } }
      assert_raises(ArgumentError) { field.audit_as('assignment.reviewed') { nil } }
      assert_equal :ok, field.audit_as('field.sensitive_acknowledged') { :ok }
    end

    test 'audit_as data cannot replace the computed changes or snapshot (A1)' do
      assignment = create_permission_set_user(user: create_user, permission_set: create_permission_set)
      assert_raises(ArgumentError) { assignment.audit_as('assignment.reviewed', data: { 'changes' => {} }) { nil } }
      assert_raises(ArgumentError) { assignment.audit_as('assignment.reviewed', data: { snapshot: {} }) { nil } }

      assignment.audit_as('assignment.reviewed', data: { 'decision' => 'keep' }) { assignment.update!(reviewed_at: Time.current) }
      event = assert_audit_event('assignment.reviewed', record_id: assignment.id.to_s)
      assert_equal %w[reviewed_at], event.data['changes'].keys
    end

    test 'an invalid nested audit_as leaves the outer one in force (A3)' do
      assignment = create_permission_set_user(user: create_user, permission_set: create_permission_set)
      assignment.audit_as('assignment.reviewed', data: { 'decision' => 'keep' }) do
        assert_raises(Audit::EventCatalog::UnknownEventError) { assignment.audit_as('assignment.nope') { nil } }
        assert_raises(ArgumentError) { assignment.audit_as('assignment.revoked') { nil } }
        assert_raises(ArgumentError) { assignment.audit_as('assignment.reviewed', data: { 'changes' => 1 }) { nil } }
        assignment.update!(reviewed_at: Time.current)
      end
      event = assert_audit_event('assignment.reviewed', record_id: assignment.id.to_s)
      assert_equal 'keep', event.data['decision']
      assert_equal 0, audit_events_for(assignment).where(event: 'assignment.changed').count
    end

    # --- records keep nothing that cannot be marshalled ------------------------------

    test 'a record that has written events can still be marshalled' do
      set = create_permission_set(name: 'Ops')
      set.update!(name: 'Ops 2')
      assert_equal 'Ops 2', Marshal.load(Marshal.dump(set)).name
    end

    # --- the class-level API the later tasks build on --------------------------------

    test 'audit_event_name gives the catalogue name per model and action' do
      assert_equal 'permission_set.updated', PermissionForge::PermissionSet.audit_event_name(:update)
      assert_equal 'assignment.revoked', PermissionForge::PermissionSetUser.audit_event_name(:destroy)
      assert_equal 'group_membership.added', PermissionForge::PermissionSetGroupUser.audit_event_name(:create)
      assert_equal 'resource_field.destroyed', PermissionForge::ResourceField.audit_event_name(:destroy)
    end

    test 'audit_reference gives the columns an event about the record carries' do
      set = create_permission_set(name: 'Ops')
      user = create_user(name: 'Holder')
      assignment = create_permission_set_user(user: user, permission_set: set)
      reference = assignment.audit_reference
      assert_equal 'PermissionForge::PermissionSetUser', reference[:record_type]
      assert_equal assignment.id.to_s, reference[:record_id]
      assert_equal assignment.uuid, reference[:record_uuid]
      assert_equal 'Holder', reference[:record_label]
      assert_equal set.id, reference[:permission_set_id]
      assert_equal set.uuid, reference[:permission_set_uuid]
      assert_equal user.id.to_s, reference[:subject_user_id]
      assert_equal DEFAULT_TEST_ACCOUNT.id, reference[:tenant_id]
    end
  end
end
