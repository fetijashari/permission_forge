require 'test_helper'

module PermissionForge
  module Audit
    # T4: the gem's own multi-step writes — clones, Permission Set factory
    # copies, group deletion and Review-and-save — leave one audited event per
    # row, credited to the acting admin, under one correlation id.
    class ChangeCoverageTest < ActiveSupport::TestCase
      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        PermissionForge.configuration.audit_trail_enabled = true
        @author = create_user(name: 'Original Author')
        @admin = create_user(name: 'Acting Admin')
        act_as(@author)
        @source = create_permission_set(name: 'Source set')
        @resource = create_resource(permission_set: @source, read_access: true, edit_access: true)
        @field = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @action = create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        @rule = create_permission_set_rule(permission_set: @source, resource: @resource)
        [@source, @resource, @field, @action, @rule].each { |row| row.update_columns(updated_by_id: @author.id) }
        act_as(@admin)
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      # --- clones ---------------------------------------------------------------

      test 'a clone credits the acting admin on every copied row and gives each a fresh uuid' do
        copy = Services::PermissionSetCloner.call(permission_set: @source, attrs: { name: 'Copy' })

        rows = copied_rows(copy)
        assert_equal 5, rows.size
        rows.each do |row|
          assert_equal @admin.id, row.created_by_id, "#{row.class.name} keeps the original author"
          assert_equal @admin.id, row.updated_by_id, "#{row.class.name} is last edited by the acting admin"
        end
        assert_empty rows.map(&:uuid) & original_rows.map(&:uuid)
      end

      test 'a clone records permission_set.cloned with the source and one correlation id for every row' do
        copy = nil
        assert_difference -> { AuditEvent.where(event: 'permission_set.cloned').count }, 1 do
          copy = Services::PermissionSetCloner.call(permission_set: @source, attrs: { name: 'Copy' })
        end

        cloned = assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, record_uuid: copy.uuid,
                                                             permission_set_id: copy.id, actor_id: @admin.id.to_s,
                                                             data: { 'source_uuid' => @source.uuid, 'source_name' => 'Source set' })
        events = AuditEvent.where(correlation_id: cloned.correlation_id).pluck(:event)
        assert_equal %w[permission_set.cloned permission_set.created permission_set_rule.created resource.created
                        resource_action.created resource_field.created], events.sort
      end

      test 'a clone keeps the correlation id of an enclosing block and the reason of the context' do
        Audit::Context.with(reason: 'TCK-1') do
          Audit.correlate('outer-id') { Services::PermissionSetCloner.call(permission_set: @source, attrs: { name: 'Copy' }) }
        end

        events = AuditEvent.where(correlation_id: 'outer-id')
        assert_equal 6, events.count
        assert_equal ['TCK-1'], events.distinct.pluck(:reason)
      end

      test 'a group clone records permission_set_group.cloned and permission_set.cloned per set under one id' do
        group = PermissionSetGroup.create!(name: 'Sales', is_active: true)
        @source.update!(permission_set_group: group)
        other = create_permission_set(name: 'Other set', permission_set_group: group)

        copy = Services::PermissionSetGroupCloner.call(permission_set_group: group, attrs: { name: 'Sales copy' })

        event = assert_audit_event('permission_set_group.cloned', record_id: copy.id.to_s, actor_id: @admin.id.to_s,
                                                                  data: { 'source_uuid' => group.uuid })
        cloned_sets = AuditEvent.where(event: 'permission_set.cloned', correlation_id: event.correlation_id)
        assert_equal [@source.uuid, other.uuid].sort, cloned_sets.map { |e| e.data['source_uuid'] }.sort
        assert_equal @admin.id, copy.created_by_id
        assert(copy.permission_sets.all? { |set| set.created_by_id == @admin.id })
        assert_not_equal group.uuid, copy.uuid
      end

      test 'deep_clone on the models goes through the cloners and records the clone' do
        copy = @source.deep_clone(name: 'Via model')

        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, data: { 'source_uuid' => @source.uuid })
      end

      # --- Permission Set factory ------------------------------------------------

      test 'duplicate creates every copied row unlocked: no unaudited update, one created event each' do
        lock_source!

        copy = nil
        assert_no_difference -> { AuditEvent.where(event: %w[resource.updated resource_field.updated permission_set_rule.updated]).count } do
          copy = Admin::PermissionSetFactory.duplicate(@source, name: 'Unlocked copy')
        end

        rows = copied_rows(copy)
        assert(rows.select { |row| row.has_attribute?(:is_editable) }.all?(&:is_editable))
        rows.each do |row|
          created = assert_audit_event("#{row.class.audit_model_key}.created", record_id: row.id.to_s)
          assert_equal true, created.data['snapshot']['is_editable'] if row.has_attribute?(:is_editable)
          assert_equal @admin.id, row.created_by_id
        end
        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, data: { 'source_uuid' => @source.uuid })
      end

      test 'start from another set copies it unlocked and records the clone' do
        lock_source!

        copy = Admin::PermissionSetFactory.create({ name: 'Started', is_muting: false, permission_set_group: nil }, source: @source)

        assert copy.is_active
        assert(copied_rows(copy).select { |row| row.has_attribute?(:is_editable) }.all?(&:is_editable))
        assert_audit_event('permission_set.cloned', record_id: copy.id.to_s, actor_id: @admin.id.to_s)
      end

      test 'a copy does not carry over the acknowledgement of a sensitive field' do
        @field.update_columns(sensitive_acknowledged_at: 1.day.ago, sensitive_acknowledged_by_id: @author.id)

        copy = Services::PermissionSetCloner.call(permission_set: @source, attrs: { name: 'Copy' })

        copied = copy.resources.first.resource_fields.first
        assert_nil copied.sensitive_acknowledged_at
        assert_nil copied.sensitive_acknowledged_by_id
        assert_not_nil @field.reload.sensitive_acknowledged_at
      end

      # --- field generation ----------------------------------------------------------

      test 'grant_full_access! records the resource and its generated fields under one correlation id' do
        set = create_permission_set(name: 'Generated')
        baseline = AuditEvent.maximum(:id).to_i

        Resource.grant_full_access!(permission_set: set, resource_name: 'Supplier')

        events = AuditEvent.where('id > ?', baseline)
        assert_operator events.where(event: 'resource_field.created').count, :>, 1
        assert_equal 1, events.where(event: 'resource.created').count
        assert_equal 1, events.distinct.count(:correlation_id)
      end

      test 'ResourceFieldGenerator records every generated field under one correlation id' do
        resource = create_resource(permission_set: @source, name: 'Supplier')
        baseline = AuditEvent.maximum(:id).to_i

        fields = Services::ResourceFieldGenerator.call(resource: resource)

        events = AuditEvent.where('id > ?', baseline)
        assert_operator fields.size, :>, 1
        assert_equal fields.size, events.where(event: 'resource_field.created').count
        assert_equal 1, events.distinct.count(:correlation_id)
      end

      test 'a field write that fails during generation commits no field and no event' do
        resource = create_resource(permission_set: @source, name: 'Supplier')

        assert_no_difference [-> { AuditEvent.count }, -> { resource.resource_fields.count }] do
          fail_second_field_write { assert_raises(ActiveRecord::RecordInvalid) { Services::ResourceFieldGenerator.call(resource: resource) } }
        end
      end

      test 'a field write that fails during grant_full_access! commits no resource and no event' do
        set = create_permission_set(name: 'Generated')

        assert_no_difference [-> { AuditEvent.count }, -> { Resource.count }] do
          fail_second_field_write do
            assert_raises(ActiveRecord::RecordInvalid) { Resource.grant_full_access!(permission_set: set, resource_name: 'Supplier') }
          end
        end
      end

      test 'a plain clone keeps the locks of the source' do
        lock_source!

        copy = Services::PermissionSetCloner.call(permission_set: @source, attrs: { name: 'Locked copy' })

        assert_not copy.resources.first.is_editable
        assert_not copy.resources.first.resource_fields.first.is_editable
      end

      # --- group deletion ----------------------------------------------------------

      test 'deleting a group detaches its sets through audited updates under one correlation id' do
        group = PermissionSetGroup.create!(name: 'Doomed', is_active: true)
        @source.update!(permission_set_group: group)
        other = create_permission_set(name: 'Other', permission_set_group: group)

        assert_difference -> { AuditEvent.where(event: 'permission_set.updated').count }, 2 do
          group.destroy!
        end

        destroyed = assert_audit_event('permission_set_group.destroyed', record_id: group.id.to_s, actor_id: @admin.id.to_s)
        assert_equal 'Doomed', destroyed.data.dig('snapshot', 'name')
        [@source, other].each do |set|
          assert_nil set.reload.permission_set_group_id
          assert_audit_event('permission_set.updated', record_id: set.id.to_s, correlation_id: destroyed.correlation_id,
                                                       data: { 'changes' => { 'permission_set_group_id' => [group.id, nil] } })
        end
      end

      test 'deleting a group detaches a locked set and one an unrelated validation would refuse' do
        group = PermissionSetGroup.create!(name: 'Doomed', is_active: true)
        lock_source!
        # a value every database holds and the set's validation refuses on any
        # save (an over-long name cannot be stored on MySQL)
        @source.update_columns(permission_set_group_id: group.id, allowed_hours_start: 99)
        refute_predicate @source, :valid?

        group.destroy!

        assert_nil @source.reload.permission_set_group_id
        assert_audit_event('permission_set.updated', record_id: @source.id.to_s)
      end

      test 'a group delete that is rolled back leaves its sets attached and no event' do
        group = PermissionSetGroup.create!(name: 'Kept', is_active: true)
        @source.update!(permission_set_group: group)

        assert_no_difference -> { AuditEvent.count } do
          PermissionSetGroup.transaction(requires_new: true) do
            group.destroy!
            raise ActiveRecord::Rollback
          end
        end
        assert_equal group.id, @source.reload.permission_set_group_id
      end

      # --- Review and save ---------------------------------------------------------

      test 'Review-and-save records every change under one correlation id with the reason of the context' do
        change_set = halfway_change_set(valid: true)

        Audit::Context.with(reason: 'TCK-1') { change_set.apply! }

        updated = assert_audit_event('resource_field.updated', record_id: @field.id.to_s, reason: 'TCK-1')
        events = AuditEvent.where(correlation_id: updated.correlation_id)
        assert_equal %w[permission_set.updated resource.updated resource_field.updated], events.pluck(:event).sort
        assert_equal ['TCK-1'], events.distinct.pluck(:reason)
      end

      test 'a Review-and-save that fails validation halfway leaves no events and no changes' do
        change_set = halfway_change_set(valid: false)

        assert_no_difference -> { AuditEvent.count } do
          assert_raises(Admin::ChangeSet::Invalid) { change_set.apply! }
        end
        assert_equal 'A test permission set', @source.reload.description
        assert_not @resource.reload.create_access
      end

      test 'a Review-and-save that fails halfway inside a caller transaction that rescues leaves nothing either' do
        change_set = halfway_change_set(valid: false)

        assert_no_difference -> { AuditEvent.count } do
          ActiveRecord::Base.transaction do
            change_set.apply!
          rescue Admin::ChangeSet::Invalid
            nil
          end
        end
        assert_equal 'A test permission set', @source.reload.description
        assert_not @resource.reload.create_access
      end

      private

      def act_as(user)
        PermissionForge.configuration.current_user_resolver = -> { user }
      end

      # The second ResourceField.create! inside the block raises, as a field
      # that fails validation would.
      def fail_second_field_write
        calls = 0
        ResourceField.define_singleton_method(:create!) do |*args, **kwargs, &block|
          calls += 1
          raise ActiveRecord::RecordInvalid, ResourceField.new if calls == 2

          super(*args, **kwargs, &block)
        end
        yield
      ensure
        ResourceField.singleton_class.remove_method(:create!)
      end

      def lock_source!
        [@source, @resource, @field, @rule].each { |row| row.update_columns(is_editable: false) }
      end

      def original_rows
        [@source, @resource, @field, @action, @rule]
      end

      def copied_rows(copy)
        resources = copy.resources.to_a
        [copy, *resources, *resources.flat_map { |r| r.resource_fields.to_a + r.resource_actions.to_a + r.permission_set_rules.to_a }]
      end

      # Set header first, then the resource, then a field whose mask strategy
      # is unknown when `valid` is false — the last record saved fails.
      def halfway_change_set(valid:)
        strategy = valid ? 'email' : 'no_such_strategy'
        Admin::ChangeSet.new(permission_set: @source, params: {
                               set: { description: 'Edited' },
                               resources: { @resource.id.to_s => { create_access: '1' } },
                               fields: { @field.id.to_s => { level: 'masked', mask_strategy: strategy } }
                             })
      end
    end
  end
end
