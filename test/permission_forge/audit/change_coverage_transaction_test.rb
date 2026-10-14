require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Audit
    # T4 with real transactions (no fixture transaction around the test): a
    # Review-and-save that fails halfway commits neither its earlier saves nor
    # their events, and a group delete commits its detach events with it.
    class ChangeCoverageTransactionTest < ActiveSupport::TestCase
      include Tenancy::TenancyTestHelper

      self.use_transactional_tests = false

      setup do
        @set = create_permission_set(name: 'Real transaction set')
        @resource = create_resource(permission_set: @set, read_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @baseline = AuditEvent.maximum(:id).to_i
      end

      teardown do
        [PermissionSetRule, ResourceAction, ResourceField, Resource, PermissionSetUser, PermissionSet, PermissionSetGroup, AuditEvent]
          .each { |model| model.unscoped.delete_all }
        Account.where.not(id: DEFAULT_TEST_ACCOUNT.id).delete_all
      end

      test 'a Review-and-save that fails validation halfway commits no change and no event' do
        assert_raises(Admin::ChangeSet::Invalid) { halfway_change_set.apply! }

        assert_empty new_events
        assert_equal 'A test permission set', @set.reload.description
        assert_not @resource.reload.create_access
      end

      test 'a caller transaction that rescues the failure commits no partial change and no event' do
        ActiveRecord::Base.transaction do
          halfway_change_set.apply!
        rescue Admin::ChangeSet::Invalid
          nil
        end

        assert_empty new_events
        assert_not @resource.reload.create_access
      end

      test 'a group delete commits one update per detached set with its destroy event, under one id' do
        group = PermissionSetGroup.create!(name: 'Doomed', is_active: true)
        @set.update!(permission_set_group: group)
        @baseline = AuditEvent.maximum(:id).to_i

        group.destroy!

        events = new_events
        assert_equal %w[permission_set.updated permission_set_group.destroyed], events.map(&:event).sort
        assert_equal 1, events.map(&:correlation_id).uniq.size
        assert_nil @set.reload.permission_set_group_id
      end

      test 'a group delete under another ambient tenant detaches the sets of the group tenant, under one id' do
        tenant_a = Account.create!(name: 'Tenant A')
        tenant_b = Account.create!(name: 'Tenant B')
        group, sets = within(tenant_a) do
          group = create_permission_set_group(name: 'Group A')
          [group, %w[A1 A2].map { |name| create_permission_set(name: name, permission_set_group: group) }]
        end
        before = sets.map { |set| PermissionSet.unscoped.find(set.id).attributes }
        @baseline = AuditEvent.unscoped.maximum(:id).to_i

        within(tenant_b) { PermissionSetGroup.unscoped.find(group.id).destroy! }

        sets.each_with_index do |set, index|
          after = PermissionSet.unscoped.find(set.id).attributes
          changed = after.keys.reject { |key| before[index][key] == after[key] } - %w[updated_at updated_by_id]
          assert_equal ['permission_set_group_id'], changed
        end
        events = AuditEvent.unscoped.where('id > ?', @baseline)
        assert_equal %w[permission_set.updated permission_set.updated permission_set_group.destroyed], events.pluck(:event).sort
        assert_equal 1, events.distinct.count(:correlation_id)
        assert_equal [tenant_a.id], events.distinct.pluck(:account_id)
      end

      test 'a field write that fails during generation commits nothing' do
        baseline_fields = ResourceField.unscoped.count
        calls = 0
        ResourceField.define_singleton_method(:create!) do |*args, **kwargs, &block|
          calls += 1
          raise ActiveRecord::RecordInvalid, ResourceField.new if calls == 2

          super(*args, **kwargs, &block)
        end

        assert_raises(ActiveRecord::RecordInvalid) { Resource.grant_full_access!(permission_set: @set, resource_name: 'Supplier') }

        assert_empty new_events
        assert_equal baseline_fields, ResourceField.unscoped.count
        assert_not Resource.unscoped.exists?(name: 'Supplier')
      ensure
        ResourceField.singleton_class.remove_method(:create!) if ResourceField.singleton_class.method_defined?(:create!, false)
      end

      private

      def new_events
        AuditEvent.where('id > ?', @baseline).to_a
      end

      def halfway_change_set
        Admin::ChangeSet.new(permission_set: @set, params: {
                               set: { description: 'Edited' },
                               resources: { @resource.id.to_s => { create_access: '1' } },
                               fields: { @field.id.to_s => { level: 'masked', mask_strategy: 'no_such_strategy' } }
                             })
      end
    end
  end
end
