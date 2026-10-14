# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  class AuditEventModelTest < ActiveSupport::TestCase
    include PermissionForge::Tenancy::TenancyTestHelper

    def build_event(attrs = {})
      PermissionForge::AuditEvent.create!({
        event: 'permission_set.created', category: 'change', actor_type: 'unknown', source: 'service',
        occurred_at: Time.current, data: { 'snapshot' => { 'name' => 'Ops' } }
      }.merge(attrs))
    end

    test 'table name follows the configured prefix at call time' do
      assert_equal 'audit_events', PermissionForge::AuditEvent.table_name
      PermissionForge.configuration.table_name_prefix = 'pf_'
      assert_equal 'pf_audit_events', PermissionForge::AuditEvent.table_name
      PermissionForge.configuration.table_name_prefix = 'permission_forge_'
      assert_equal 'permission_forge_audit_events', PermissionForge::AuditEvent.table_name
    ensure
      PermissionForge.configuration.table_name_prefix = ''
    end

    test 'a uuid is generated and the row carries no updated_at' do
      event = build_event
      assert_match(/\A[0-9a-f-]{36}\z/, event.uuid)
      assert_not PermissionForge::AuditEvent.column_names.include?('updated_at')
      assert PermissionForge::AuditEvent.column_names.include?('created_at')
    end

    test 'data is stored as JSON text and read back as a Hash with string keys' do
      event = build_event(data: { changes: { name: %w[Old New] }, at: Time.utc(2026, 1, 2, 3, 4, 5) })
      reloaded = PermissionForge::AuditEvent.find(event.id)
      assert_equal({ 'changes' => { 'name' => %w[Old New] }, 'at' => '2026-01-02T03:04:05.000Z' }, reloaded.data)
      assert_kind_of String, reloaded.read_attribute_before_type_cast(:data)
    end

    test 'data defaults to an empty Hash' do
      assert_equal({}, PermissionForge::AuditEvent.new.data)
      assert_equal({}, PermissionForge::AuditEvent.find(build_event(data: nil).id).data)
    end

    test 'a persisted event is read-only: update raises' do
      event = build_event
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(reason: 'changed my mind') }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.update(reason: 'changed my mind') }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.save! }
      assert_nil PermissionForge::AuditEvent.find(event.id).reason
    end

    test 'a persisted event is read-only: update_columns and touch raise' do
      event = build_event
      assert_raises(ActiveRecord::ActiveRecordError) { event.update_columns(reason: 'x') }
      assert_raises(ActiveRecord::ActiveRecordError) { event.touch(:occurred_at) }
      assert_nil PermissionForge::AuditEvent.find(event.id).reason
    end

    test 'a persisted event is read-only: destroy and delete raise' do
      event = build_event
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
      assert PermissionForge::AuditEvent.exists?(event.id)
    end

    test 'a persisted event is read-only: counters and upserts raise' do
      event = build_event(permission_set_id: 5)
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.increment!(:permission_set_id) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.decrement!(:permission_set_id) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.toggle!(:reason) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { event.update_attribute(:reason, 'x') }
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.update_counters(event.id, permission_set_id: 1) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.update(event.id, reason: 'x') }
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.destroy(event.id) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.where(id: event.id).destroy_all }
      forged = event.attributes.except('id').merge('reason' => 'forged', 'data' => '{}')
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.upsert(forged, unique_by: :uuid) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.upsert_all([forged], unique_by: :uuid) }
      assert_equal [nil, 5], PermissionForge::AuditEvent.where(id: event.id).pick(:reason, :permission_set_id)
    end

    # Rails 8.2 (main) runs increment! / decrement! through the relation's
    # update_counters (`self.class.unscoped.where(id:).update_counters`),
    # past the class method: the relation refuses it too.
    test 'a persisted event is read-only: a relation cannot update its counters' do
      event = build_event(permission_set_id: 5)
      assert_raises(ActiveRecord::ReadOnlyRecord) { PermissionForge::AuditEvent.where(id: event.id).update_counters(permission_set_id: 1) }
      assert_raises(ActiveRecord::ReadOnlyRecord) do
        PermissionForge::AuditEvent.unscoped.where(id: event.id).update_counters(permission_set_id: -1, touch: true)
      end
      assert_equal 5, PermissionForge::AuditEvent.where(id: event.id).pick(:permission_set_id)
    end

    test 'the sanctioned relation paths stay reachable: update_all (erasure), delete_all and delete(id) (purge)' do
      event = build_event(actor_label: 'Erased Person')
      other = build_event
      assert_equal 1, PermissionForge::AuditEvent.where(id: event.id).update_all(actor_label: nil)
      assert_nil PermissionForge::AuditEvent.find(event.id).actor_label
      assert_equal 1, PermissionForge::AuditEvent.where(id: event.id).delete_all
      assert_equal 1, PermissionForge::AuditEvent.delete(other.id)
      assert_not PermissionForge::AuditEvent.exists?(other.id)
    end

    test 'for_record finds the events of a subclass instance under the base class' do
      subclass = Class.new(PermissionForge::PermissionSet)
      event = build_event(record_type: 'PermissionForge::PermissionSet', record_id: '42')
      assert_equal [event], PermissionForge::AuditEvent.for_record(subclass.new(id: 42)).to_a
    end

    test 'event, category, actor_type and source are validated against the contract' do
      assert_raises(ActiveRecord::RecordInvalid) { build_event(category: 'weird') }
      assert_raises(ActiveRecord::RecordInvalid) { build_event(actor_type: 'robot') }
      assert_raises(ActiveRecord::RecordInvalid) { build_event(source: 'pigeon') }
      assert_raises(ActiveRecord::RecordInvalid) { build_event(event: nil) }
    end

    test 'events are scoped to the ambient tenant and carry its id' do
      other = Account.create!(name: 'Other')
      mine = build_event
      theirs = within(other) { build_event }
      assert_equal DEFAULT_TEST_ACCOUNT.id, mine.account_id
      assert_equal other.id, theirs.account_id
      assert_includes PermissionForge::AuditEvent.all, mine
      assert_not_includes PermissionForge::AuditEvent.all, theirs
      within(other) { assert_includes PermissionForge::AuditEvent.all, theirs }
    end

    test 'an event follows the tenant of its subject, not the ambient one' do
      other = Account.create!(name: 'Other')
      event = PermissionForge::AuditEvent.new(
        event: 'permission_set.created', category: 'change', actor_type: 'unknown', source: 'service',
        occurred_at: Time.current
      )
      event.subject_tenant_id = other.id
      event.save!
      stored = ActsAsTenant.without_tenant { PermissionForge::AuditEvent.find(event.id) }
      assert_equal other.id, stored.account_id
    end

    test 'scopes: for_record, for_subject, in_period, newest first' do
      set = PermissionForge::PermissionSet.new(id: 42)
      recorded = build_event(record_type: 'PermissionForge::PermissionSet', record_id: '42', subject_user_id: '7',
                             occurred_at: 2.days.ago)
      build_event(record_type: 'PermissionForge::PermissionSet', record_id: '0', occurred_at: 10.days.ago)
      assert_equal [recorded], PermissionForge::AuditEvent.for_record(set).to_a
      assert_equal [recorded], PermissionForge::AuditEvent.for_subject('7').to_a
      assert_equal [recorded], PermissionForge::AuditEvent.between(3.days.ago, Time.current).to_a
      assert_equal recorded, PermissionForge::AuditEvent.newest_first.first
    end
  end
end
