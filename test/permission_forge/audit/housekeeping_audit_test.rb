require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  # T6: erasure, consent withdrawal and the expired-assignment clean-up leave
  # per-row events (from the callbacks) plus one summary event with the actor.
  class HousekeepingAuditTest < ActiveSupport::TestCase
    include Tenancy::TenancyTestHelper

    setup do
      @admin = create_user(name: 'Ada Admin')
      @user = create_user(name: 'Erin Erased')
      @set = create_permission_set(name: 'Marketing', requires_session_flag: 'marketing_consent')
      @other = create_permission_set(name: 'Support')
      @assignment = create_permission_set_user(user: @user, permission_set: @set)
      create_permission_set_user(user: @user, permission_set: @other)
    end

    def summary(name, **filters)
      PermissionForge::AuditEvent.where(event: name, **filters).order(:id).last
    end

    def event_about_user_in_other_tenant
      other_tenant = Account.create!(name: 'Other tenant')
      other_set = within(other_tenant) { create_permission_set(name: 'Elsewhere') }
      within(other_tenant) { create_permission_set_user(user: @user, permission_set: other_set) }
      other_event = within(other_tenant) do
        PermissionForge::Audit.record('report.generated', actor: { type: 'user', id: @user.id, label: 'Erin Erased' }, data: {})
      end
      [other_tenant, other_event]
    end

    # --- erasure -------------------------------------------------------------

    test 'erasure writes per-row revoked events and one summary naming the actor, sets and counts' do
      group = create_permission_set_group(name: 'Everyone')
      PermissionForge::PermissionSetGroupUser.create!(uuid: SecureRandom.uuid, user: @user, permission_set_group: group)

      assert_difference -> { PermissionForge::AuditEvent.where(event: 'assignment.revoked').count }, 2 do
        Services::DataSubjectErasure.call(user: @user, actor: @admin, reason: 'GDPR request 7')
      end

      event = summary('erasure.performed')
      data = event.data
      assert_equal @admin.id.to_s, event.actor_id
      assert_equal 'Ada Admin', event.actor_label
      assert_equal @user.id.to_s, event.subject_user_id
      assert_equal 'GDPR request 7', event.reason
      assert_equal 'service', event.source
      assert_equal [@set.uuid, @other.uuid].sort, data['set_uuids'].sort
      assert_equal %w[Marketing Support], data['set_names'].sort
      assert_equal ['Everyone'], data['group_names']
      assert_equal [2, 1, false], data.values_at('assignments_removed', 'group_assignments_removed', 'dry_run')
      assert_equal @user.id.to_s, data['subject_user_id']
      assert_equal 'erasure', data['operation']
      revokes = PermissionForge::AuditEvent.where(event: 'assignment.revoked', subject_user_id: @user.id.to_s)
      assert_equal [event.correlation_id], revokes.pluck(:correlation_id).uniq
    end

    test 'erasure dry run writes no event at all' do
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        Services::DataSubjectErasure.call(user: @user, dry_run: true, actor: @admin)
      end
    end

    test 'erasure clears the labels naming the person and keeps every id' do
      grant = PermissionForge::AuditEvent.where(event: 'assignment.granted', subject_user_id: @user.id.to_s).first
      assert_equal 'Erin Erased', grant.record_label

      Services::DataSubjectErasure.call(user: @user, actor: @admin)

      assert_predicate PermissionForge::AuditEvent.where(subject_user_id: @user.id.to_s).where.not(record_label: nil), :none?
      assert_equal @assignment.id.to_s, grant.reload.record_id
      assert_equal @user.id.to_s, grant.subject_user_id
      scrubbed = summary('erasure.performed').data['events_scrubbed']
      assert_operator scrubbed, :>=, 3 # two grants and the two revokes are labelled with the person
    end

    test 'erasure of a user who is also an admin actor keeps actor_id and loses actor_label' do
      PermissionForge.with_audit_actor(user: @user) { create_permission_set(name: 'Made by Erin') }
      past = PermissionForge::AuditEvent.where(event: 'permission_set.created', actor_id: @user.id.to_s).last
      assert_equal 'Erin Erased', past.actor_label

      Services::DataSubjectErasure.call(user: @user, actor: @admin)

      past.reload
      assert_equal @user.id.to_s, past.actor_id
      assert_nil past.actor_label
      assert_equal 'Made by Erin', past.record_label
      assert_operator summary('erasure.performed').data['actor_labels_cleared'], :>=, 1
    end

    test 'a person erasing themselves leaves no name on the events of the erasure' do
      Services::DataSubjectErasure.call(user: @user, actor: @user)

      event = summary('erasure.performed')
      assert_equal @user.id.to_s, event.actor_id
      assert_nil event.actor_label
      assert_predicate PermissionForge::AuditEvent.where(correlation_id: event.correlation_id).where.not(actor_label: nil), :none?
    end

    # A tenant admin cannot reach another tenant's log: with a tenant current
    # the labels are cleared in that tenant's events only.
    test 'erasure with a tenant current clears the labels in that tenant and counts what remains in other tenants' do
      other_tenant, other_event = event_about_user_in_other_tenant
      own_event = PermissionForge::Audit.record('report.generated', actor: { type: 'user', id: @user.id, label: 'Erin Erased' },
                                                                    data: {})

      result = Services::DataSubjectErasure.call(user: @user, actor: @admin)

      assert_nil own_event.reload.actor_label
      assert_equal 'Erin Erased', PermissionForge::AuditEvent.unscoped.find(other_event.id).actor_label
      assert_equal 1, result[:assignments_remaining_elsewhere]
      assert_equal 1, summary('erasure.performed').data['assignments_remaining_elsewhere']
      assert_equal 1, within(other_tenant) { PermissionForge::PermissionSetUser.where(user: @user).count }
    end

    # The rake task, a platform operator: no tenant, every tenant's events
    # (and the events that have none).
    test 'erasure with no tenant clears the labels in every tenant' do
      _, other_event = event_about_user_in_other_tenant
      no_tenant!
      untenanted = PermissionForge::Audit.record('report.generated', actor: { type: 'user', id: @user.id, label: 'Erin Erased' },
                                                                     data: {})

      Services::DataSubjectErasure.call(user: @user, actor: @admin)

      assert_nil PermissionForge::AuditEvent.unscoped.find(other_event.id).actor_label
      assert_nil PermissionForge::AuditEvent.unscoped.find(untenanted.id).actor_label
    end

    test 'only actors of type user are scrubbed, an api key sharing the id keeps its label' do
      api = PermissionForge::Audit.record('report.generated', actor: { type: 'api', id: @user.id, label: 'Billing key' }, data: {})
      basic = PermissionForge::Audit.record('report.generated', actor: { type: 'basic_auth', id: @user.id, label: 'ops' }, data: {})

      Services::DataSubjectErasure.call(user: @user, actor: @admin)

      assert_equal 'Billing key', api.reload.actor_label
      assert_equal 'ops', basic.reload.actor_label
    end

    test 'an api principal sharing the id is not treated as the erased person acting' do
      Services::DataSubjectErasure.call(user: @user, actor: { type: 'api', id: @user.id, label: 'Billing key' })

      assert_equal 'Billing key', summary('erasure.performed').actor_label
    end

    test 'self-erasure with no actor: but the person as current_user leaves no name on the summary' do
      previous = PermissionForge.configuration.current_user_resolver
      PermissionForge.configuration.current_user_resolver = -> { @user }

      Services::DataSubjectErasure.call(user: @user)

      event = summary('erasure.performed')
      assert_equal @user.id.to_s, event.actor_id
      assert_nil event.actor_label
    ensure
      PermissionForge.configuration.current_user_resolver = previous
    end

    test 'a raising on_erasure callback: the erasure stands, is recorded, and the error propagates' do
      error = assert_raises(RuntimeError) do
        Services::DataSubjectErasure.call(user: @user, actor: @admin, on_erasure: ->(_user) { raise 'host failed' })
      end

      assert_equal 'host failed', error.message
      assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count
      assert_predicate PermissionForge::AuditEvent.where(subject_user_id: @user.id.to_s).where.not(record_label: nil), :none?
      assert summary('erasure.performed')
    end

    test 'a summary that cannot be written leaves assignments, events and labels as they were' do
      labelled = PermissionForge::AuditEvent.where(subject_user_id: @user.id.to_s).where.not(record_label: nil).count
      klass = PermissionForge::AuditEvent.singleton_class
      klass.alias_method(:__orig_store!, :store!)
      klass.define_method(:store!) do |attrs|
        attrs[:event] == 'erasure.performed' ? raise(ActiveRecord::StatementInvalid, 'boom') : __orig_store!(attrs)
      end

      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        assert_raises(PermissionForge::Audit::EventNotRecordedError) { Services::DataSubjectErasure.call(user: @user, actor: @admin) }
      end

      assert_equal 2, PermissionForge::PermissionSetUser.where(user: @user).count
      assert_equal labelled, PermissionForge::AuditEvent.where(subject_user_id: @user.id.to_s).where.not(record_label: nil).count
    ensure
      replace_method(klass, :store!, klass.instance_method(:__orig_store!))
      klass.remove_method(:__orig_store!)
    end

    test 'erasure with a label String actor is a system actor' do
      Services::DataSubjectErasure.call(user: @user, actor: 'DPO ticket 9')

      event = summary('erasure.performed')
      assert_equal 'system', event.actor_type
      assert_equal 'DPO ticket 9', event.actor_label
      assert_nil event.actor_id
    end

    test 'a nil actor leaves the context actor in place' do
      PermissionForge.with_audit_actor(user: @admin, source: 'admin_ui') do
        Services::DataSubjectErasure.call(user: @user, actor: nil)
      end

      event = summary('erasure.performed')
      assert_equal @admin.id.to_s, event.actor_id
      assert_equal 'admin_ui', event.source
    end

    test 'the source stays rake or job when the caller says so' do
      PermissionForge.with_audit_actor(label: 'nightly', source: 'job') do
        Services::DataSubjectErasure.call(user: @user)
      end

      assert_equal 'job', summary('erasure.performed').source
    end

    # --- consent -------------------------------------------------------------

    test 'consent withdrawal writes the summary with flag, sets and counts' do
      Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent', actor: @admin, reason: 'opt-out')

      event = summary('consent.withdrawn')
      assert_equal @admin.id.to_s, event.actor_id
      assert_equal @user.id.to_s, event.subject_user_id
      assert_equal 'opt-out', event.reason
      assert_equal ['Marketing'], event.data['set_names']
      assert_equal [@set.uuid], event.data['set_uuids']
      assert_equal [1, 'marketing_consent', false], event.data.values_at('revoked', 'consent_flag', 'dry_run')
      assert_audit_event('assignment.revoked', subject_user_id: @user.id.to_s)
    end

    test 'a consent summary that cannot be written leaves every assignment in place' do
      klass = PermissionForge::AuditEvent.singleton_class
      klass.alias_method(:__orig_store!, :store!)
      klass.define_method(:store!) do |attrs|
        attrs[:event] == 'consent.withdrawn' ? raise(ActiveRecord::StatementInvalid, 'boom') : __orig_store!(attrs)
      end

      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        assert_raises(PermissionForge::Audit::EventNotRecordedError) do
          Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent', actor: @admin)
        end
      end

      assert PermissionForge::PermissionSetUser.exists?(@assignment.id), 'the revocation rolled back with its summary'
    ensure
      replace_method(klass, :store!, klass.instance_method(:__orig_store!))
      klass.remove_method(:__orig_store!)
    end

    test 'consent withdrawal invalidates the cache only after the revocations and summary commit' do
      invalidated_inside = nil
      user = @user
      user.define_singleton_method(:invalidate_permissions) do |**kwargs|
        invalidated_inside = !PermissionForge::OpenTransaction.current.nil? if invalidated_inside.nil?
        super(**kwargs)
      end

      result = Services::ConsentWithdrawalHandler.call(user: user, consent_flag: 'marketing_consent', actor: @admin)

      assert_equal 1, result[:revoked_sets]
      assert result[:invalidated]
      assert_equal false, invalidated_inside, 'the explicit invalidation runs after the commit'
      assert_not summary('consent.withdrawn').data.key?('invalidated'), 'the summary cannot know what the store confirms later'
    end

    test 'consent withdrawal dry run writes nothing' do
      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        Services::ConsentWithdrawalHandler.call(user: @user, consent_flag: 'marketing_consent', dry_run: true)
      end
    end

    # --- clean-up ------------------------------------------------------------

    test 'clean-up writes per-row revoked events and one summary' do
      @assignment.update_columns(expires_at: 2.days.ago)

      assert_difference -> { PermissionForge::AuditEvent.where(event: 'assignment.revoked').count }, 1 do
        Services::ExpiredAssignmentCleaner.call(actor: @admin)
      end

      event = summary('cleanup.expired_assignments')
      assert_equal @admin.id.to_s, event.actor_id
      assert_equal ['Marketing'], event.data['set_names']
      assert_equal [1, [@user.id.to_s], false], event.data.values_at('removed', 'affected_user_ids', 'dry_run')
    end

    test 'clean-up dry run writes nothing and a run over nothing writes no summary' do
      @assignment.update_columns(expires_at: 2.days.ago)

      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        Services::ExpiredAssignmentCleaner.call(dry_run: true, actor: @admin)
      end

      @assignment.destroy
      assert_no_difference -> { PermissionForge::AuditEvent.where(event: 'cleanup.expired_assignments').count } do
        Services::ExpiredAssignmentCleaner.call
      end
    end

    test 'under :report an unwritable summary does not block the erasure' do
      PermissionForge.configuration.audit_change_failure_strategy = :report
      klass = PermissionForge::AuditEvent.singleton_class
      klass.alias_method(:__orig_store!, :store!)
      klass.define_method(:store!) do |attrs|
        attrs[:event] == 'erasure.performed' ? raise(ActiveRecord::StatementInvalid, 'boom') : __orig_store!(attrs)
      end

      result = Services::DataSubjectErasure.call(user: @user, actor: @admin)

      assert_equal 2, result[:assignments_removed]
      assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count
      assert_nil summary('erasure.performed', subject_user_id: @user.id.to_s)
    ensure
      replace_method(klass, :store!, klass.instance_method(:__orig_store!))
      klass.remove_method(:__orig_store!)
    end
  end
end
