# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # The collection writers Rails generates for the associations the gem
    # declares (on the host's User through PermissionedUser, on
    # PermissionSet and on PermissionSetGroup). Each one must remove rows
    # through callbacks — so the change is an audit event and the person's
    # cached permissions are dropped — and must never destroy the Permission
    # Set, group or person at the other end of a join row.
    class AssociationWritersTest < ActiveSupport::TestCase
      include IntegrationSupport

      setup do
        @ana = create_user(name: 'Ana', email: 'ana@example.test')
        @bo = create_user(name: 'Bo', email: 'bo@example.test')
        @set = create_permission_set(name: 'Sales')
        @other_set = create_permission_set(name: 'Support')
        create_resource(permission_set: @set, name: 'Customer', read_access: true)
        @group = create_permission_set_group(name: 'Front office')
        @set.update!(permission_set_group: @group)
        @other_set.update!(permission_set_group: @group)
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
        @other_assignment = create_permission_set_user(user: @ana, permission_set: @other_set)
        @membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @ana)
      end

      # label => [writer, the events it must write]
      REVOKING = {
        'user.permission_sets.delete(set)' => [-> { @ana.permission_sets.delete(@set) }, %w[assignment.revoked]],
        'user.permission_sets.destroy(set)' => [-> { @ana.permission_sets.destroy(@set) }, %w[assignment.revoked]],
        'user.permission_set_ids = [other]' => [-> { @ana.permission_set_ids = [@other_set.id] }, %w[assignment.revoked]],
        'user.permission_sets = [other]' => [-> { @ana.permission_sets = [@other_set] }, %w[assignment.revoked]],
        'user.permission_sets.clear' => [-> { @ana.permission_sets.clear }, %w[assignment.revoked]],
        'user.permission_sets.delete_all' => [-> { @ana.permission_sets.delete_all }, %w[assignment.revoked]],
        'user.permission_set_users.clear' => [-> { @ana.permission_set_users.clear }, %w[assignment.revoked]],
        'user.permission_set_users.delete(row)' => [-> { @ana.permission_set_users.delete(@assignment) }, %w[assignment.revoked]],
        'set.users.delete(user)' => [-> { @set.users.delete(@ana) }, %w[assignment.revoked]],
        'set.users.destroy(user)' => [-> { @set.users.destroy(@ana) }, %w[assignment.revoked]],
        'set.user_ids = []' => [-> { @set.user_ids = [] }, %w[assignment.revoked]],
        'set.users = []' => [-> { @set.users = [] }, %w[assignment.revoked]],
        'set.users.clear' => [-> { @set.users.clear }, %w[assignment.revoked]],
        'set.permission_set_users.delete_all' => [-> { @set.permission_set_users.delete_all }, %w[assignment.revoked]],
        'user.permission_sets.destroy_all' => [-> { @ana.permission_sets.destroy_all }, %w[assignment.revoked]],
        'set.users.destroy_all' => [-> { @set.users.destroy_all }, %w[assignment.revoked]]
      }.freeze

      UNGROUPING = {
        'user.permission_set_groups.delete(group)' => -> { @ana.permission_set_groups.delete(@group) },
        'user.permission_set_group_ids = []' => -> { @ana.permission_set_group_ids = [] },
        'user.permission_set_groups.clear' => -> { @ana.permission_set_groups.clear },
        'group.users.delete(user)' => -> { @group.users.delete(@ana) },
        'group.user_ids = []' => -> { @group.user_ids = [] },
        'group.users.clear' => -> { @group.users.clear },
        'group.permission_set_group_users.delete_all' => -> { @group.permission_set_group_users.delete_all }
      }.freeze

      DETACHING = {
        'group.permission_sets.delete(set)' => [-> { @group.permission_sets.delete(@set) }, 1],
        'group.permission_set_ids = [other]' => [-> { @group.permission_set_ids = [@other_set.id] }, 1],
        'group.permission_sets = []' => [-> { @group.permission_sets = [] }, 2],
        'group.permission_sets.clear' => [-> { @group.permission_sets.clear }, 2],
        'group.permission_sets.delete_all' => [-> { @group.permission_sets.delete_all }, 2]
      }.freeze

      REVOKING.each do |label, (writer, names)|
        test "#{label} revokes through the assignment's callbacks" do
          assert @ana.can_read?('Customer'), 'the cached hash grants read before the writer'

          events = ledger_events { instance_exec(&writer) }

          assert_tables_explained(label)
          assert_equal names, events.map(&:event).uniq
          assert_not PermissionSetUser.exists?(@assignment.id), 'the assignment row is gone'
          assert_people_sets_and_groups_intact
          assert_not User.find(@ana.id).can_read?('Customer'), 'a fresh instance must not read the revoked grant from the cache'
          revoked = events.find { |event| event.record_id == @assignment.id.to_s }
          assert revoked, "#{label}: no event names assignment ##{@assignment.id}"
          assert_equal @ana.id.to_s, revoked.subject_user_id
          assert_equal @set.id.to_s, revoked.permission_set_id.to_s
        end
      end

      UNGROUPING.each do |label, writer|
        test "#{label} removes the membership through its callbacks" do
          events = ledger_events { instance_exec(&writer) }

          assert_tables_explained(label)
          assert_equal %w[group_membership.removed], events.map(&:event).uniq
          assert_not PermissionSetGroupUser.exists?(@membership.id)
          assert_people_sets_and_groups_intact
          assert PermissionSetUser.exists?(@assignment.id), 'a group membership is not an assignment'
        end
      end

      DETACHING.each do |label, (writer, count)|
        test "#{label} detaches each set with an audited save" do
          events = ledger_events { instance_exec(&writer) }

          assert_tables_explained(label)
          assert_equal ['permission_set.updated'] * count, events.map(&:event)
          events.each { |event| assert_equal [@group.id, nil], event.data.dig('changes', 'permission_set_group_id') }
          assert_nil @set.reload.permission_set_group_id
          assert_people_sets_and_groups_intact
          assert PermissionSetUser.exists?(@assignment.id), 'detaching a set keeps its assignments'
        end
      end

      test 'clearing the permission collections destroys each row with its event' do
        resource = @set.resources.first
        create_resource_field(resource: resource, name: 'email')
        create_resource_action(resource: resource, name: 'export')
        create_permission_set_rule(permission_set: @set, resource: resource)

        events = ledger_events do
          resource.resource_fields.clear
          resource.resource_actions.delete_all
          @set.permission_set_rules.clear
          @set.resources.clear
        end

        assert_tables_explained('clear')
        assert_equal %w[permission_set_rule.destroyed resource.destroyed resource_action.destroyed resource_field.destroyed],
                     events.map(&:event).uniq.sort
        assert_equal 0, @set.resources.count
        assert PermissionSet.exists?(@set.id)
      end

      test 'an explicit SQL strategy is left to Rails' do
        assert_equal 1, @ana.permission_set_users.where(permission_set: @set).delete_all
        assert_equal 1, @ana.permission_set_users.delete_all(:delete_all)
      end

      test 'a set instance loaded before it joined the group is detached with an event' do
        late = create_permission_set(name: 'Late')
        held = PermissionSet.find(late.id)
        PermissionSet.find(late.id).update!(permission_set_group: @group)

        events = ledger_events { @group.permission_sets.delete(held) }

        assert_tables_explained('stale instance')
        assert_equal %w[permission_set.updated], events.map(&:event)
        assert_nil late.reload.permission_set_group_id
      end

      test 'a writer whose event cannot be written changes nothing' do
        assert_raises(Audit::EventNotRecordedError) do
          failing_store(%w[assignment.revoked]) { @ana.permission_sets.delete(@set) }
        end
        assert PermissionSetUser.exists?(@assignment.id)

        assert_raises(Audit::EventNotRecordedError) do
          failing_store(%w[permission_set.updated]) { @group.permission_sets.delete(@set) }
        end
        assert_equal @group.id, @set.reload.permission_set_group_id
      end

      test 'adding through the associations is recorded' do
        events = ledger_events do
          @bo.permission_sets << @set
          @group.users << @bo
          @group.permission_sets << create_permission_set(name: 'Late')
        end

        assert_tables_explained('adds')
        assert_equal %w[assignment.granted group_membership.added permission_set.created permission_set.updated].sort,
                     events.map(&:event).uniq.sort
      end

      # dependent: :destroy on a :through association destroys the join rows
      # only — never the records at the other end, also on the owner's destroy.
      test 'destroying a person removes their join rows and nothing else' do
        @ana.permission_sets.load
        @ana.permission_set_groups.load

        events = ledger_events { @ana.destroy! }

        assert_tables_explained('user.destroy')
        assert_equal %w[assignment.revoked group_membership.removed], events.map(&:event).uniq.sort
        assert_equal(2, events.count { |event| event.event == 'assignment.revoked' })
        assert PermissionSet.exists?(@set.id)
        assert PermissionSet.exists?(@other_set.id)
        assert PermissionSetGroup.exists?(@group.id)
        assert User.exists?(@bo.id)
      end

      test 'destroying a Permission Set never destroys its people or group' do
        @set.users.load

        ledger_events { @set.destroy! }

        assert_tables_explained('set.destroy')
        assert User.exists?(@ana.id)
        assert PermissionSetGroup.exists?(@group.id)
        assert PermissionSet.exists?(@other_set.id)
        assert PermissionSetUser.exists?(@other_assignment.id)
      end

      test 'destroying a group never destroys its people or sets' do
        @group.users.load
        @group.permission_sets.load

        events = ledger_events { @group.destroy! }

        assert_tables_explained('group.destroy')
        assert_includes events.map(&:event), 'group_membership.removed'
        assert User.exists?(@ana.id)
        assert PermissionSet.exists?(@set.id)
        assert PermissionSet.exists?(@other_set.id)
        assert_nil @set.reload.permission_set_group_id
        assert PermissionSetUser.exists?(@assignment.id)
      end

      private

      def assert_people_sets_and_groups_intact
        assert User.exists?(@ana.id), 'the person is never destroyed'
        assert User.exists?(@bo.id)
        assert PermissionSet.exists?(@set.id), 'the Permission Set is never destroyed'
        assert PermissionSet.exists?(@other_set.id)
        assert PermissionSetGroup.exists?(@group.id), 'the group is never destroyed'
      end
    end
  end
end
