require_relative 'admin_test_case'

module PermissionForge
  module Html
    # Every admin path that gives or takes access writes its audit event with
    # the acting admin and the person concerned, and asks
    # config.admin_assignment_authorization first.
    class AssignmentAuditFlowsTest < AdminTestCase
      setup do
        @admin = create_user(name: 'Ada Admin', email: 'ada@acme.test')
        @old_resolver = PermissionForge.configuration.current_user_resolver
        admin = @admin
        PermissionForge.configuration.current_user_resolver = -> { admin }
        @calls = []
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      test 'assign with an end date, then undo from the toast' do
        other = create_permission_set(name: 'Support')
        third = create_permission_set(name: 'Billing')

        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [other.id, third.id], expiry: '1w' }

        granted = PermissionForge::PermissionSetUser.where(user: @bo).to_a
        assert_equal 2, granted.size
        events = granted.map do |row|
          assert_audit_event('assignment.granted', record_id: row.id.to_s, subject_user_id: @bo.id.to_s,
                                                   actor_id: @admin.id.to_s, actor_label: 'Ada Admin', source: 'admin_ui')
        end
        assert_equal 1, events.map(&:correlation_id).uniq.size, 'one assign action shares one correlation id'
        assert_equal Time.zone.today + 7, Time.zone.parse(events.first.data['snapshot']['expires_at']).to_date

        undo = flash[:pf_undo]
        post undo[:path], params: undo[:params]

        revoked = granted.map { |row| assert_audit_event('assignment.revoked', record_id: row.id.to_s, actor_id: @admin.id.to_s) }
        assert_equal 1, revoked.map(&:correlation_id).uniq.size
      end

      test 'assigning several sets is all or nothing' do
        first = create_permission_set(name: 'A first') # the form assigns in name order
        second = create_permission_set(name: 'Z second')
        model = PermissionForge::PermissionSetUser
        original = model.method(:create!)
        replace_singleton_method(model, :create!) do |*args, **attrs, &block|
          raise ActiveRecord::RecordNotSaved, 'forced' if attrs[:permission_set] == second

          original.call(*args, **attrs, &block)
        end
        begin
          assert_no_difference -> { PermissionForge::AuditEvent.where(event: 'assignment.granted').count } do
            assert_raises(ActiveRecord::RecordNotSaved) do
              post pf('/assignments'), params: { user_id: @bo.id, set_ids: [first.id, second.id], expiry: 'never' }
            end
          end
        ensure
          replace_singleton_method(model, :create!, original)
        end
        assert_not PermissionForge::PermissionSetUser.exists?(user: @bo, permission_set: first), 'the first set is rolled back too'
      end

      test 'Keep and acknowledge store no reviewer id when the admin is not a record' do
        PermissionForge.configuration.current_user_resolver = -> {}
        as_basic_auth { post pf("/assignments/#{@assignment.id}/keep"), headers: @basic_auth_headers }
        assert @assignment.reload.reviewed_at
        assert_nil @assignment.reviewed_by_id
        assert_audit_event('assignment.reviewed', record_id: @assignment.id.to_s, actor_type: 'basic_auth', actor_label: 'ops',
                                                  actor_id: nil, source: 'admin_ui')

        as_basic_auth do
          post pf("/permission_sets/#{@set.id}/resources/Customer/fields/email/acknowledge"), headers: @basic_auth_headers
        end
        assert @email.reload.sensitive_acknowledged_at
        assert_nil @email.sensitive_acknowledged_by_id
      end

      test 'remove, then restore from the toast' do
        @assignment.update!(expires_at: 5.days.from_now.end_of_day)
        delete pf("/assignments/#{@assignment.id}")
        revoked = assert_audit_event('assignment.revoked', record_id: @assignment.id.to_s, subject_user_id: @ana.id.to_s,
                                                           actor_id: @admin.id.to_s)
        assert revoked.data['snapshot']['expires_at']

        undo = flash[:pf_undo]
        post undo[:path], params: undo[:params]
        restored = PermissionForge::PermissionSetUser.find_by(user: @ana, permission_set: @set)
        event = assert_audit_event('assignment.granted', record_id: restored.id.to_s, actor_id: @admin.id.to_s)
        assert_equal Time.zone.today + 5, Time.zone.parse(event.data['snapshot']['expires_at']).to_date
      end

      test 'change the end date and extend by 30 days' do
        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'eom' }
        changed = assert_audit_event('assignment.changed', record_id: @assignment.id.to_s, actor_id: @admin.id.to_s)
        assert_nil changed.data['changes']['expires_at'].first

        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'extend30' }
        extended = assert_audit_event('assignment.changed', record_id: @assignment.id.to_s)
        from, to = extended.data['changes']['expires_at'].map { |value| Time.zone.parse(value).to_date }
        assert_equal Time.zone.today.end_of_month, from
        assert_equal Time.zone.today.end_of_month + 30, to
      end

      test 'Keep records the reviewer in one event; a later edit keeps the review' do
        @assignment.update_columns(created_at: 200.days.ago)
        assert_difference -> { audit_events_for(@assignment).count }, 1 do
          post pf("/assignments/#{@assignment.id}/keep")
        end

        @assignment.reload
        assert_equal @admin.id, @assignment.reviewed_by_id
        assert @assignment.reviewed_at > 1.minute.ago
        assert_audit_event('assignment.reviewed', record_id: @assignment.id.to_s, actor_id: @admin.id.to_s,
                                                  subject_user_id: @ana.id.to_s, data: { 'decision' => 'keep' })
        assert_empty PermissionForge::Admin::AttentionItems.new.stale

        patch pf("/assignments/#{@assignment.id}"), params: { expiry: 'eom' }
        assert_equal @admin.id, @assignment.reload.reviewed_by_id
      end

      test 'bulk assign and bulk revoke record one event per person' do
        post pf("/permission_sets/#{@set.id}/bulk_assignment"), params: { identifiers: 'bo@acme.test', expiry: 'never' }
        bo_row = PermissionForge::PermissionSetUser.find_by(user: @bo, permission_set: @set)
        assert_audit_event('assignment.granted', record_id: bo_row.id.to_s, subject_user_id: @bo.id.to_s, actor_id: @admin.id.to_s)

        delete pf("/permission_sets/#{@set.id}/bulk_assignment/revoke"), params: { user_ids: [@ana.id, @bo.id] }
        events = [@assignment, bo_row].map do |row|
          assert_audit_event('assignment.revoked', record_id: row.id.to_s, actor_id: @admin.id.to_s)
        end
        assert_equal 1, events.map(&:correlation_id).uniq.size
      end

      test 'remove all access records each revocation under one correlation id' do
        second = create_permission_set_user(user: @ana, permission_set: create_permission_set(name: 'Support'))
        delete pf("/people/#{@ana.id}/remove_all")

        events = [@assignment, second].map do |row|
          assert_audit_event('assignment.revoked', record_id: row.id.to_s, subject_user_id: @ana.id.to_s, actor_id: @admin.id.to_s)
        end
        assert_equal 1, events.map(&:correlation_id).uniq.size
      end

      test 'group members added and removed' do
        group = create_permission_set_group(name: 'Support team')
        post pf("/groups/#{group.id}/members"), params: { user_id: @bo.id }
        membership = PermissionForge::PermissionSetGroupUser.find_by(user: @bo, permission_set_group: group)
        assert_audit_event('group_membership.added', record_id: membership.id.to_s, subject_user_id: @bo.id.to_s,
                                                     actor_id: @admin.id.to_s)

        delete pf("/groups/#{group.id}/members/#{membership.id}")
        assert_audit_event('group_membership.removed', record_id: membership.id.to_s, actor_id: @admin.id.to_s)
      end

      test 'This is intended records who acknowledged the field in one event' do
        assert_difference -> { audit_events_for(@email).count }, 1 do
          post pf("/permission_sets/#{@set.id}/resources/Customer/fields/email/acknowledge")
        end
        assert_equal @admin.id, @email.reload.sensitive_acknowledged_by_id
        event = assert_audit_event('field.sensitive_acknowledged', record_id: @email.id.to_s, actor_id: @admin.id.to_s)
        assert_equal [nil, @admin.id], event.data['changes']['sensitive_acknowledged_by_id']
      end

      # --- config.admin_assignment_authorization -------------------------------------

      test 'a self-assignment refused by the lambda changes nothing and records only the refusal' do
        refuse_self
        assert_refusals_only(1) do
          post pf('/assignments'), params: { user_id: @admin.id, set_ids: [@set.id], expiry: 'never' }
        end
        assert_audit_event('admin.auth_failed', actor_id: @admin.id.to_s, source: 'admin_ui', subject_user_id: @admin.id.to_s,
                                                permission_set_id: @set.id,
                                                data: { 'reason' => 'assignment_not_authorized', 'action' => 'grant' })
        assert_redirected_to pf("/people/#{@admin.id}")
        assert_equal I18n.t('permission_forge.flash.assignment_not_authorized'), flash[:alert]
        assert_not PermissionForge::PermissionSetUser.exists?(user: @admin)
        assert_equal [[@set.id, [@admin.id], :grant]], @calls

        post pf('/assignments'), params: { user_id: @bo.id, set_ids: [@set.id], expiry: 'never' }
        assert PermissionForge::PermissionSetUser.exists?(user: @bo, permission_set: @set)
      end

      test 'every admin path asks the lambda with its action, and a refusal leaves no change' do
        own = create_permission_set_user(user: @admin, permission_set: create_permission_set(name: 'Admins'))
        group = create_permission_set_group(name: 'Ops')
        own_membership = PermissionForge::PermissionSetGroupUser.create!(user: @admin, permission_set_group: group)
        refuse_self

        assert_refusals_only(10) do
          patch pf("/assignments/#{own.id}"), params: { expiry: 'extend30' }
          post pf("/assignments/#{own.id}/keep")
          delete pf("/assignments/#{own.id}")
          post pf('/assignments/undo'), params: { ids: [own.id] }
          post pf('/assignments/restore'), params: { permission_set_id: @set.id, user_id: @admin.id }
          post pf("/permission_sets/#{@set.id}/bulk_assignment"), params: { identifiers: 'ada@acme.test', expiry: 'never' }
          delete pf("/permission_sets/#{own.permission_set_id}/bulk_assignment/revoke"), params: { user_ids: [@admin.id] }
          delete pf("/people/#{@admin.id}/remove_all")
          post pf("/groups/#{group.id}/members"), params: { user_id: @admin.id }
          delete pf("/groups/#{group.id}/members/#{own_membership.id}")
        end

        assert_equal %i[change_expiry review revoke revoke grant grant revoke revoke add_member remove_member], @calls.map(&:last)
        assert(@calls.all? { |_, ids, _| ids == [@admin.id] })
        assert_nil own.reload.expires_at
        assert_nil own.reviewed_at
        assert PermissionForge::PermissionSetGroupUser.exists?(own_membership.id)
        assert_not PermissionForge::PermissionSetUser.exists?(user: @admin, permission_set: @set)
      end

      private

      # A real HTTP Basic login (the request context names the actor).
      def as_basic_auth
        config = PermissionForge.configuration
        config.http_basic_auth_enabled = true
        config.http_basic_auth_user = 'ops'
        config.http_basic_auth_password = 'pw'
        @basic_auth_headers = { 'HTTP_AUTHORIZATION' => ActionController::HttpAuthentication::Basic.encode_credentials('ops', 'pw') }
        yield
      ensure
        config.http_basic_auth_enabled = false
        config.http_basic_auth_user = config.http_basic_auth_password = nil
        @basic_auth_headers = nil
      end

      # The block changes nothing (no change event) and records `count` refusals.
      def assert_refusals_only(count, &)
        assert_no_difference(-> { PermissionForge::AuditEvent.where(category: 'change').count }) do
          assert_difference(-> { PermissionForge::AuditEvent.where(event: 'admin.auth_failed').count }, count, &)
        end
      end

      def refuse_self
        calls = @calls
        admin = @admin
        PermissionForge.configuration.admin_assignment_authorization = lambda { |controller, target, user_ids, action|
          raise 'not a controller' unless controller.is_a?(ActionController::Base)

          calls << [target.id, user_ids, action]
          !user_ids.include?(admin.id)
        }
      end
    end
  end
end
