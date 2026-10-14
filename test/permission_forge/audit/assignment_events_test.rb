require 'test_helper'

module PermissionForge
  module Audit
    # Assignments and memberships: the events carry the actor, the person, the
    # expiry and the reason; "Keep" is one assignment.reviewed event.
    class AssignmentEventsTest < ActiveSupport::TestCase
      setup do
        @admin = create_user(name: 'Ada Admin')
        @holder = create_user(name: 'Holder')
        @set = create_permission_set(name: 'Sales rep')
      end

      test 'a grant records the actor, the person, the expiry and the reason from the context, also on the row' do
        ends = 10.days.from_now.end_of_day
        assignment = PermissionForge.with_audit_actor(user: @admin) do
          Audit::Context.with(reason: 'TCK-9') do
            PermissionSetUser.create!(user: @holder, permission_set: @set, expires_at: ends)
          end
        end

        assert_equal 'TCK-9', assignment.reload.reason
        event = assert_audit_event('assignment.granted', record_id: assignment.id.to_s, subject_user_id: @holder.id.to_s,
                                                         actor_id: @admin.id.to_s, actor_label: 'Ada Admin', reason: 'TCK-9',
                                                         permission_set_uuid: @set.uuid)
        assert_equal 'TCK-9', event.data['snapshot']['reason']
        assert_equal ends.to_date, Time.zone.parse(event.data['snapshot']['expires_at']).to_date
      end

      # The row keeps the reason as the event stores it: PostgreSQL refuses a
      # NUL in a text column (a host's with_audit_actor reason, or the request's).
      test 'the reason kept on the row is cleaned like the event column' do
        assignment = Audit::Context.with(reason: "TCK\u0000-9\nurgent") do
          PermissionSetUser.create!(user: @holder, permission_set: @set)
        end
        membership = Audit::Context.with(reason: "a\u0000b") do
          PermissionSetGroupUser.create!(uuid: SecureRandom.uuid, permission_set_group: create_permission_set_group,
                                         user: @holder)
        end

        assert_equal 'TCK-9 urgent', assignment.reload.reason
        assert_equal 'ab', membership.reload.reason if membership.has_attribute?(:reason)
      end

      test 'an expiry change carries the previous and new end date and its reason' do
        assignment = create_permission_set_user(user: @holder, permission_set: @set, expires_at: 2.days.from_now)
        Audit::Context.with(reason: 'extended for audit') { assignment.update!(expires_at: 30.days.from_now) }

        event = assert_audit_event('assignment.changed', record_id: assignment.id.to_s, reason: 'extended for audit')
        from, to = event.data['changes']['expires_at']
        assert_equal 2.days.from_now.to_date, Time.zone.parse(from).to_date
        assert_equal 30.days.from_now.to_date, Time.zone.parse(to).to_date
        assert_equal [nil, 'extended for audit'], event.data['changes']['reason']
      end

      test 'the reason is left alone without a context reason, and a save with no change writes nothing' do
        assignment = Audit::Context.with(reason: 'first') { create_permission_set_user(user: @holder, permission_set: @set) }
        assignment.update!(expires_at: 5.days.from_now)
        assert_equal 'first', assignment.reload.reason

        assert_no_difference -> { audit_events_for(assignment).count } do
          Audit::Context.with(reason: 'nothing changed') { assignment.save! }
        end
        assert_equal 'first', assignment.reload.reason
      end

      test 'a revocation snapshots the assignment, with the reason from the context' do
        assignment = create_permission_set_user(user: @holder, permission_set: @set, expires_at: 3.days.from_now)
        PermissionForge.with_audit_actor(user: @admin, reason: 'left the team') { assignment.destroy! }

        event = assert_audit_event('assignment.revoked', record_id: assignment.id.to_s, subject_user_id: @holder.id.to_s,
                                                         actor_id: @admin.id.to_s, reason: 'left the team')
        assert_equal @set.id, event.data['snapshot']['permission_set_id']
        assert event.data['snapshot']['expires_at']
      end

      test 'group memberships keep the context reason on the row and on the events' do
        group = create_permission_set_group(name: 'Support')
        membership = PermissionForge.with_audit_actor(user: @admin) do
          Audit::Context.with(reason: 'TCK-10') { PermissionSetGroupUser.create!(user: @holder, permission_set_group: group) }
        end
        assert_equal 'TCK-10', membership.reload.reason
        assert_audit_event('group_membership.added', record_id: membership.id.to_s, subject_user_id: @holder.id.to_s,
                                                     actor_id: @admin.id.to_s, reason: 'TCK-10')

        Audit::Context.with(reason: 'TCK-11') { membership.destroy! }
        assert_audit_event('group_membership.removed', record_id: membership.id.to_s, reason: 'TCK-11')
      end

      test 'a duplicate assignment is refused and leaves no event' do
        create_permission_set_user(user: @holder, permission_set: @set)
        duplicate = PermissionSetUser.new(user: @holder, permission_set: @set)

        assert_no_difference -> { AuditEvent.where(event: 'assignment.granted').count } do
          assert_not duplicate.save
        end
      end

      # --- access review --------------------------------------------------------------

      test 'Keep records the reviewer in one assignment.reviewed event, and survives a later edit' do
        assignment = create_permission_set_user(user: @holder, permission_set: @set)
        travel_to(1.hour.from_now) do
          assert_difference -> { audit_events_for(assignment).count }, 1 do
            PermissionForge.with_audit_actor(user: @admin) { assignment.mark_reviewed!(reviewer: @admin) }
          end
        end

        assignment.reload
        assert_equal @admin.id, assignment.reviewed_by_id
        reviewed_at = assignment.reviewed_at
        assert reviewed_at
        event = assert_audit_event('assignment.reviewed', record_id: assignment.id.to_s, actor_id: @admin.id.to_s,
                                                          subject_user_id: @holder.id.to_s, data: { 'decision' => 'keep' })
        assert_equal [nil, @admin.id], event.data['changes']['reviewed_by_id']
        assert_equal 0, audit_events_for(assignment).where(event: 'assignment.changed').count

        assignment.update!(expires_at: 30.days.from_now)
        assignment.reload
        assert_equal @admin.id, assignment.reviewed_by_id
        assert_equal reviewed_at.to_i, assignment.reviewed_at.to_i
        assert_audit_event('assignment.changed', record_id: assignment.id.to_s)
      end

      test 'Keep without the review columns still records the review (upgrade migration not run)' do
        assignment = create_permission_set_user(user: @holder, permission_set: @set)
        assignment.update_columns(updated_at: 200.days.ago)
        without_review_columns do
          assert_difference -> { audit_events_for(assignment).where(event: 'assignment.reviewed').count }, 1 do
            assignment.mark_reviewed!(reviewer: @admin)
          end
          assert_nil assignment.reload.reviewed_at
          assert assignment.updated_at > 1.minute.ago
          assert_empty PermissionSetUser.stale_before(90.days.ago).where(id: assignment.id)
        end
      end

      private

      def without_review_columns
        PermissionSetUser.singleton_class.alias_method(:pf_original_review_supported?, :review_supported?)
        PermissionSetUser.define_singleton_method(:review_supported?) { false }
        yield
      ensure
        owner = PermissionSetUser.singleton_class
        replace_method(owner, :review_supported?, owner.instance_method(:pf_original_review_supported?))
        owner.remove_method(:pf_original_review_supported?)
      end
    end
  end
end
