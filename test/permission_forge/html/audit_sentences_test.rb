# frozen_string_literal: true

require_relative 'admin_test_case'

module PermissionForge
  module Html
    # The sentence of an audit event says what was true when it happened:
    # the Permission Set, group and person under the names they had then, a
    # revocation by the clean-up as the removal of an expired assignment, and
    # a field read with the fields that were hidden or masked, if any.
    class AuditSentencesTest < AdminTestCase
      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        @admin = create_user(name: 'Ada Admin')
        admin = @admin
        PermissionForge.configuration.current_user_resolver = -> { admin }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      def sentences(**params)
        get pf('/audit'), params: params
        assert_response :success
        css_select('.pf-audit-event__sentence').map { |node| node.text.squish }
      end

      def sentence_of(event)
        get pf("/audit/#{event.uuid}")
        assert_response :success
        css_select('.pf-audit-event__sentence, h1').map { |node| node.text.squish }.join(' | ')
      end

      test 'a renamed and deleted set is named as it was at each event, never by its id' do
        set = PermissionForge.with_audit_actor(user: @admin) { create_permission_set(name: 'Payroll') }
        added = PermissionForge.with_audit_actor(user: @admin) { create_resource(permission_set: set, name: 'Supplier') }
        PermissionForge.with_audit_actor(user: @admin) { set.update!(name: 'Salaries') }
        PermissionForge.with_audit_actor(user: @admin) { added.update!(edit_access: true) }
        PermissionForge.with_audit_actor(user: @admin) { set.destroy! }

        listed = sentences(permission_set: set.id)

        assert_includes listed, 'Ada Admin added the resource Supplier to Payroll.'
        assert_includes listed, 'Ada Admin changed the resource Supplier in Salaries.'
        assert_includes listed, 'Ada Admin removed the resource Supplier from Salaries.'
        assert_includes listed, 'Ada Admin deleted the Permission Set Salaries.'
        assert_includes listed, 'Ada Admin created the Permission Set Payroll.'
        assert(listed.none? { |text| text.include?("##{set.id}") }, listed.inspect)
      end

      test 'an event about a set renamed while nothing was recorded uses the name the rename started from' do
        set = create_permission_set(name: 'Payroll')
        PermissionForge.configuration.audit_events = false
        set.update!(name: 'Before recording')
        PermissionForge.configuration.audit_events = :auto
        PermissionForge::Audit.reset!
        resource = PermissionForge.with_audit_actor(user: @admin) { create_resource(permission_set: set, name: 'Supplier') }
        PermissionForge::AuditEvent.where(record_type: 'PermissionForge::PermissionSet', record_id: set.id.to_s).delete_all
        PermissionForge.with_audit_actor(user: @admin) { set.update!(name: 'After') }

        event = assert_audit_event('resource.created', record_id: resource.id.to_s)
        assert_includes sentences(permission_set: set.id), 'Ada Admin added the resource Supplier to Before recording.'
        assert event
      end

      test 'a renamed group and person are named as they were' do
        group = create_permission_set_group(name: 'Front office')
        cy = create_user(name: 'Cy Old')
        PermissionForge.with_audit_actor(user: @admin) do
          PermissionSetGroupUser.create!(permission_set_group: group, user: cy)
          create_permission_set_user(user: cy, permission_set: @set)
        end
        group.update!(name: 'Back office')
        cy.update!(name: 'Cy New')

        listed = sentences(subject_user_id: cy.id)

        assert_includes listed, 'Ada Admin added Cy Old to Front office.'
        assert_includes listed, 'Ada Admin gave Cy Old the Permission Set Sales rep.'
      end

      test 'a revocation by the clean-up says the assignment had expired, and carries a reason' do
        @assignment.update!(expires_at: Time.zone.local(2026, 2, 20, 12))
        PermissionForge.with_audit_actor(user: @admin) { Services::ExpiredAssignmentCleaner.call }

        revoked = assert_audit_event('assignment.revoked', record_id: @assignment.id.to_s)
        assert_equal 'expired', revoked.reason
        assert_includes sentences(event: 'assignment.revoked'),
                        'Ada Admin removed Sales rep from Ana Krasniqi after it expired on 20 Feb 2026.'

        other = create_permission_set_user(user: @bo, permission_set: @set, expires_at: 1.hour.ago)
        Services::ExpiredAssignmentCleaner.call(reason: 'TCK-9')
        assert_equal 'TCK-9', assert_audit_event('assignment.revoked', record_id: other.id.to_s).reason
      end

      test 'a revocation before the expiry reads as a plain removal' do
        @assignment.update!(expires_at: 1.month.from_now)
        PermissionForge.with_audit_actor(user: @admin) { @assignment.destroy! }

        assert_includes sentences(event: 'assignment.revoked'), 'Ada Admin removed Sales rep from Ana Krasniqi.'
      end

      test 'naming sets as they were reads a bounded slice of their history, not all of it' do
        set = travel_to(11.days.ago) { PermissionForge.with_audit_actor(user: @admin) { create_permission_set(name: 'Busy') } }
        start = 10.days.ago
        rows = Array.new(2000) do |i|
          { uuid: SecureRandom.uuid, event: 'permission_set.updated', category: 'change', actor_type: 'system', actor_label: 'x',
            source: 'console', record_type: 'PermissionForge::PermissionSet', record_id: set.id.to_s,
            record_label: i == 1999 ? 'Busy then' : 'Busy before', permission_set_id: set.id, occurred_at: start + i.minutes,
            data: { 'changes' => { 'description' => ['a' * 200, 'b' * 200] } } }
        end
        PermissionForge::AuditEvent.insert_all(rows)
        PermissionForge.with_audit_actor(user: @admin) { create_resource(permission_set: set, name: 'Supplier') }

        loaded = 0
        counter = ->(*, payload) { loaded += payload[:record_count] if payload[:class_name] == 'PermissionForge::AuditEvent' }
        listed = ActiveSupport::Notifications.subscribed(counter, 'instantiation.active_record') { sentences }

        assert_includes listed, 'Ada Admin added the resource Supplier to Busy then.'
        assert_operator loaded, :<=, 60, 'the page (50 events) and a few lookups, not the whole history'

        # A filtered page: the name comes from the set's one latest event before the page.
        loaded = 0
        filtered = ActiveSupport::Notifications.subscribed(counter, 'instantiation.active_record') do
          sentences(event: 'resource.created')
        end
        assert_includes filtered, 'Ada Admin added the resource Supplier to Busy then.'
        assert_operator loaded, :<=, 5
      end

      test 'a field read names the fields hidden or masked, and reads plainly when there were none' do
        store = lambda do |data|
          PermissionForge::AuditEvent.store!(uuid: SecureRandom.uuid, event: 'field.access', category: 'access',
                                             actor_type: 'user', actor_id: @bo.id.to_s, actor_label: 'Bo Berisha',
                                             source: 'runtime', record_type: 'Customer', record_id: '42',
                                             occurred_at: Time.current, data: data)
        end
        store.call({ 'model' => 'Customer', 'hidden' => ['domain'], 'masked' => ['email'], 'unconfigured' => [],
                     'bypassed' => [], 'passed' => 1, 'passed_fields' => ['name'] })
        store.call({ 'model' => 'Customer', 'hidden' => [], 'masked' => [], 'unconfigured' => [], 'bypassed' => [],
                     'passed' => 2, 'passed_fields' => %w[name email] })

        listed = sentences(event: 'field.access')

        assert_includes listed, 'Bo Berisha read Customer #42 with these fields hidden or masked: domain, email.'
        assert_includes listed, 'Bo Berisha read Customer #42.'
      end

      test 'a cache clear that reached only its own in-memory store says so; one on a shared store reads as before' do
        store = lambda do |process_local|
          PermissionForge::AuditEvent.store!(uuid: SecureRandom.uuid, event: 'cache.cleared', category: 'system',
                                             actor_type: 'system', actor_label: 'Ops on-call', source: 'rake',
                                             occurred_at: Time.current,
                                             data: { 'operation' => 'cache_clear', 'strategy' => 'pattern',
                                                     'process_local' => process_local })
        end
        store.call(true)
        store.call(false)

        listed = sentences(event: 'cache.cleared')

        assert_includes listed, 'Ops on-call cleared the cached permissions of every user in its own process only ' \
                                '(an in-memory store): the web and job processes kept theirs.'
        assert_includes listed, 'Ops on-call cleared the cached permissions of every user.'
      end
    end
  end
end
