require 'test_helper'
require_relative 'csv_reading'

module PermissionForge
  module Admin
    # The audit log read model, its exports and the "last edited by" lookup.
    class AuditLogTest < ActiveSupport::TestCase
      setup do
        PermissionForge.configuration.audit_trail_enabled = true
        @ana = create_user(name: 'Ana Krasniqi')
        @bo = create_user(name: 'Bo Berisha')
        @set = create_permission_set(name: 'Sales')
      end

      def record(event, **payload)
        PermissionForge::Audit.record(event, **payload)
      end

      def log(scope: PermissionForge::AuditEvent.all, **filters)
        AuditLog.new(filters, scope: scope)
      end

      # ---- filters -------------------------------------------------------------------

      test 'filters through Audit::EventQuery, newest first' do
        granted = PermissionForge.with_audit_actor(user: @ana) { create_permission_set_user(user: @bo, permission_set: @set) }
        event = assert_audit_event('assignment.granted', record_id: granted.id.to_s)

        found = log(event: 'assignment.granted', permission_set: @set.id.to_s, actor_type: 'user', actor_id: @ana.id.to_s,
                    subject_user_id: @bo.id.to_s, correlation_id: event.correlation_id, category: 'change').relation

        assert_equal [event], found.to_a
        assert_equal [], log(event: 'assignment.revoked', permission_set: @set.id.to_s).relation.to_a
        ordered = log.relation.to_a
        assert_equal ordered.sort_by { |e| [e.occurred_at, e.id] }.reverse, ordered
      end

      test 'only the filter parameters are kept, blank ones dropped' do
        filters = AuditLog.filters(ActionController::Parameters.new(event: 'audit.viewed', from: '', page: '3', foo: 'x'))

        assert_equal({ 'event' => 'audit.viewed' }, filters.to_h)
      end

      test 'an invalid filter raises EventQuery::Invalid naming each parameter' do
        error = assert_raises(PermissionForge::Audit::EventQuery::Invalid) do
          log(from: '2026-02-30', event: 'no.such_event', actor_id: %w[1 2]).relation
        end

        assert_equal %i[actor_id event from], error.errors.keys.sort
      end

      # ---- pages ---------------------------------------------------------------------

      test 'pages: no cap, the last page holds the rest, garbage and overflow are clamped' do
        scope = PermissionForge::AuditEvent.where(event: 'report.generated')
        7.times { |i| record('report.generated', data: { 'n' => i }) }

        first = log(scope: scope).page(1, per_page: 3)
        last = log(scope: scope).page(3, per_page: 3)

        assert_equal [7, 3, 3, 1, 3], [first.total, first.events.size, first.pages, first.first_index, first.last_index]
        assert_equal [1, 7, 7], [last.events.size, last.first_index, last.last_index]
        assert_not last.next?
        assert last.previous?
        assert_equal 3, log(scope: scope).page('99', per_page: 3).number
        assert_equal 1, log(scope: scope).page('abc', per_page: 3).number
        # one reader (ParamShapes.integer): any whole number past the last page is the last page
        assert_equal 3, log(scope: scope).page('9' * 40, per_page: 3).number
        assert_equal 1, log(scope: scope).page('2abc', per_page: 3).number
        all = (1..3).flat_map { |n| log(scope: scope).page(n, per_page: 3).events.map { |e| e.data['n'] } }
        assert_equal [6, 5, 4, 3, 2, 1, 0], all
      end

      test 'a person: events about them or by them; a set: its own events' do
        PermissionForge.with_audit_actor(user: @ana) { create_permission_set_user(user: @bo, permission_set: @set) }
        other = create_permission_set(name: 'Other')

        by_ana = log(scope: AuditLog.for_person(@ana.id)).relation.pluck(:event)
        about_bo = log(scope: AuditLog.for_person(@bo.id)).relation.pluck(:event)
        set_events = log(scope: AuditLog.for_permission_set(@set)).relation.pluck(:event)

        assert_includes by_ana, 'assignment.granted'
        assert_includes about_bo, 'assignment.granted'
        assert_includes set_events, 'permission_set.created'
        assert_includes set_events, 'assignment.granted'
        assert_not_includes log(scope: AuditLog.for_permission_set(other)).relation.pluck(:event), 'assignment.granted'
      end

      test 'without the audit table every list is empty and nothing is queried' do
        original = AuditLog.method(:table?)
        replace_singleton_method(AuditLog, :table?) { false }

        assert_equal 0, log.page(1).total
        assert_equal [], AuditLog.known_people
        assert_equal 0, AuditLog.for_person(@ana.id).count
      ensure
        replace_singleton_method(AuditLog, :table?, original)
      end

      test 'known people: acting people by recorded name, subjects by the user model' do
        PermissionForge.with_audit_actor(user: @ana) { create_permission_set_user(user: @bo, permission_set: @set) }
        people = AuditLog.known_people.to_h

        assert_equal 'Ana Krasniqi', people[@ana.id.to_s]
        assert_equal 'Bo Berisha', people[@bo.id.to_s]
      end

      test 'events are grouped by category for the event filter' do
        groups = AuditLog.event_names_by_category

        assert_equal %w[change admin system access], groups.keys
        assert_includes groups['change'], 'assignment.granted'
        assert_includes groups['access'], 'access.denied'
      end

      # ---- exports -------------------------------------------------------------------

      def export(relation, format, **)
        Exports::Events.call(relation, filters: { 'event' => 'report.generated' }, **).render(format)
      end

      # [metadata Hash, header, rows]
      def parse_csv(text)
        CsvReading.export(text)
      end

      test 'CSV: a metadata block, every column, every row across batches, oldest first' do
        12.times { |i| record('report.generated', data: { 'n' => i }) }
        relation = log(event: 'report.generated').relation
        actor = PermissionForge::Audit::Actor.new(type: 'user', id: @ana.id, label: 'Ana Krasniqi')

        meta, header, rows = parse_csv(export(relation, :csv, batch_size: 5, exported_by: actor))

        assert_equal %w[export exported_at time_zone exported_by exported_by_type exported_by_id filters row_count], meta.keys
        assert_equal ['audit_events', 'Ana Krasniqi', 'user', @ana.id.to_s],
                     meta.values_at('export', 'exported_by', 'exported_by_type', 'exported_by_id')
        assert_equal({ 'event' => 'report.generated', 'include_views' => true }, JSON.parse(meta['filters']))
        assert_equal '12', meta['row_count']
        assert_equal Exports::Events.columns, header
        assert_includes header, 'record_id'
        assert_includes header, 'actor_id'
        assert_equal 12, rows.size
        assert_equal((0..11).to_a, rows.map { |row| JSON.parse(row[header.index('data')])['n'] })
      end

      test 'JSON: meta, columns and every row' do
        3.times { |i| record('report.generated', data: { 'n' => i }) }

        body = JSON.parse(export(log(event: 'report.generated').relation, :json, batch_size: 2))

        assert_equal 3, body['meta']['row_count']
        assert_equal 3, body['data'].size
        assert_equal Exports::Events.columns, body['columns']
        assert_equal([0, 1, 2], body['data'].map { |row| row['data']['n'] })
      end

      test 'the rows are fixed when the export starts: an event written meanwhile is not in it' do
        2.times { record('report.generated') }
        document = Exports::Events.call(log(event: 'report.generated').relation, filters: {})
        record('report.generated')

        meta, _header, rows = parse_csv(document.render(:csv))

        assert_equal ['2', 2], [meta['row_count'], rows.size]
      end

      test 'CSV cells that a spreadsheet would run are neutralised' do
        record('report.generated', reason: '=HYPERLINK("http://evil","x")',
                                   actor: { type: 'system', label: '+cmd|calc' }, data: { 'a' => '@x' })

        _meta, header, rows = parse_csv(export(log(event: 'report.generated').relation, :csv))
        row = rows.last

        assert_equal %('=HYPERLINK("http://evil","x")), row[header.index('reason')]
        assert_equal "'+cmd|calc", row[header.index('actor_label')]
        %w[= + - @].each { |char| assert_equal "'#{char}1", Csv.cell("#{char}1") }
        assert_equal "'\t1", Csv.cell("\t1")
        assert_equal %("a,""b"""), Csv.cell('a,"b"')
        assert_equal "1\r\n", Csv.line([1])
      end

      test 'who holds what: every assignment with grant, expiry, review and reason' do
        grant = PermissionForge.with_audit_actor(label: 'ops', type: 'basic_auth', reason: 'TCK-1') do
          create_permission_set_user(user: @bo, permission_set: @set, expires_at: 3.days.from_now)
        end
        kept = create_permission_set_user(user: @ana, permission_set: @set)
        kept.mark_reviewed!(reviewer: @bo)

        meta, header, rows = parse_csv(Exports::Holdings.call.render(:csv))
        by_id = rows.to_h { |row| [row[header.index('assignment_id')], header.zip(row).to_h] }

        assert_equal Exports::Holdings::COLUMNS, header
        assert_equal 'holdings', meta['export']
        assert_equal rows.size.to_s, meta['row_count']
        granted = by_id[grant.id.to_s]
        assert_equal ['basic_auth', I18n.t('permission_forge.audit_log.actor_named.basic_auth', name: 'ops'), 'Bo Berisha', 'Sales', 'TCK-1', 'false'],
                     granted.values_at('granted_by_type', 'granted_by', 'person', 'permission_set', 'reason', 'expired')
        assert_predicate granted['expires_at'], :present?
        assert_predicate granted['reviewed_at'], :blank?
        reviewed = by_id[kept.id.to_s]
        assert_equal [@bo.id.to_s, 'Bo Berisha'], reviewed.values_at('reviewed_by_id', 'reviewed_by')
        assert_predicate reviewed['reviewed_at'], :present?
      end

      # Review of round 7 (P2-9): "who holds what" is a document people read;
      # its granted_by named an API client nobody named `api_client` (the
      # stored code). It names the actor as the admin does
      # (Admin::ActorLabel), in the export's language; the events export
      # keeps the stored values.
      test 'who holds what names an actor stored as a code in the language of the export' do
        grant = PermissionForge.with_audit_actor(label: PermissionForge::Audit::ActorCodes::API_CLIENT, type: 'api') do
          create_permission_set_user(user: @bo, permission_set: @set)
        end

        I18n.with_locale(:sq) do
          _meta, header, rows = parse_csv(Exports::Holdings.call.render(:csv))
          granted = header.zip(rows.find { |row| row[header.index('assignment_id')] == grant.id.to_s }).to_h

          assert_equal ['api', I18n.t('permission_forge.audit_log.actor_codes.api_client')], granted.values_at('granted_by_type', 'granted_by')
        end
        _meta, header, rows = parse_csv(Exports::Events.call(log(event: 'assignment.granted').relation, filters: {}).render(:csv))
        event = header.zip(rows.find { |row| row[header.index('event')] == 'assignment.granted' && row[header.index('actor_type')] == 'api' }).to_h

        assert_equal PermissionForge::Audit::ActorCodes::API_CLIENT, event['actor_label'], 'the events export keeps the stored value'
      end

      test 'who holds what falls back to created_by without a grant event' do
        assignment = create_permission_set_user(user: @bo, permission_set: @set)
        PermissionForge::AuditEvent.where(record_type: 'PermissionForge::PermissionSetUser', record_id: assignment.id.to_s).delete_all
        assignment.update_columns(created_by_id: @ana.id)

        body = JSON.parse(Exports::Holdings.call.render(:json))
        row = body['data'].find { |r| r['assignment_id'] == assignment.id }

        assert_equal ['user', @ana.id, 'Ana Krasniqi'], row.values_at('granted_by_type', 'granted_by_id', 'granted_by')
      end

      test 'who holds what reads its rows batch by batch, not all at once' do
        5.times { |i| create_permission_set_user(user: create_user(name: "P#{i}"), permission_set: @set) }
        loaded = []
        counter = lambda do |*, payload|
          loaded << payload[:record_count] if payload[:class_name] == 'PermissionForge::PermissionSetUser'
        end

        ActiveSupport::Notifications.subscribed(counter, 'instantiation.active_record') do
          document = Exports::Holdings.call(batch_size: 2)

          assert_empty loaded, 'building the document reads no assignment'
          document.csv.first(2) # the head, then the first row

          assert_equal [2], loaded, 'the first row reads one batch only'
          document.csv.to_a

          assert_equal [2, 2, 2, 1], loaded, 'the first batch again, then 2 + 2 + 1 assignments'
        end
      end

      test 'who holds what reads its batches outside the request query cache' do
        3.times { |i| create_permission_set_user(user: create_user(name: "P#{i}"), permission_set: @set) }
        seen = []
        spy = Module.new do
          define_method(:people_by_id) do |batch|
            seen << ActiveRecord::Base.connection.query_cache_enabled
            super(batch)
          end
        end
        Exports::Holdings.prepend(spy)

        ActiveRecord::Base.cache { Exports::Holdings.call(batch_size: 2).render(:csv) }

        assert_equal [false, false], seen
      end

      test 'who holds what is the same file whatever the batch size, row_count first' do
        5.times { |i| create_permission_set_user(user: create_user(name: "P#{i}"), permission_set: @set) }
        now = Time.current
        by = PermissionForge::Audit::Actor.current

        whole = Exports::Holdings.call(exported_by: by, now: now).render(:csv)
        batched = Exports::Holdings.call(exported_by: by, now: now, batch_size: 2)

        assert_equal whole, batched.render(:csv)
        assert_equal Exports::Holdings.call(exported_by: by, now: now).render(:json), batched.render(:json)
        meta, _header, rows = parse_csv(whole)

        assert_equal PermissionForge::PermissionSetUser.count, rows.size
        assert_equal rows.size.to_s, meta['row_count']
      end

      # ---- last edited by ------------------------------------------------------------------

      test 'the last editor is the actor of the latest change event, not a kept updated_by' do
        PermissionForge.with_audit_actor(user: @ana) { @set.update!(description: 'by Ana') }
        PermissionForge.with_audit_actor(label: 'ops', type: 'basic_auth') { @set.update!(description: 'by ops') }

        assert_equal @ana.id, @set.reload.updated_by_id
        last = LastChanges.new([@set])[@set]
        assert_equal %w[basic_auth ops], [last.actor_type, last.actor_label]
        assert_nil LastChanges.new([@set], events: %w[permission_set.created])[@set].actor_id
      end

      test 'changes_by lists what a person created or really last edited; the CSV has no cap' do
        made = PermissionForge.with_audit_actor(user: @ana) { create_permission_set(name: 'Mine') }
        taken = PermissionForge.with_audit_actor(user: @bo) { create_permission_set(name: 'Theirs') }
        PermissionForge.with_audit_actor(user: @ana) { taken.update!(description: 'Ana') }
        PermissionForge.with_audit_actor(label: 'ops', type: 'basic_auth') { taken.update!(description: 'ops') }
        edited = PermissionForge.with_audit_actor(user: @bo) { create_permission_set(name: 'Edited') }
        PermissionForge.with_audit_actor(user: @ana) { edited.update!(description: 'Ana') }

        names = AuditTrail.new.changes_by(@ana.id)['permission_set'].map { |entry| entry.record.name }
        entry = AuditTrail.new.changes_by(@ana.id)['permission_set'].find { |e| e.record == edited }

        assert_equal %w[Edited Mine].sort, names.sort
        assert_equal @ana.id.to_s, entry.editor_id
        assert_equal entry.last_event.occurred_at, entry.updated_at
        assert_equal 1, AuditTrail.new.changes_by(@ana.id, limit: 1)['permission_set'].size
        assert_not AuditTrail.const_defined?(:PER_TYPE_LIMIT)
        assert_equal made.id, AuditTrail.new.changes_by(@ana.id)['permission_set'].map(&:record).min_by(&:id).id
      end

      test 'without events the columns stand' do
        PermissionForge.configuration.audit_events = false
        @set.update_columns(updated_by_id: @bo.id)

        entry = AuditTrail.new.for_permission_set(@set).find { |e| e.type == 'permission_set' }

        assert_nil entry.last_event
        assert_equal @bo.id.to_s, entry.editor_id
        assert_equal @set.updated_at, entry.updated_at
      end

      # ---- review round 1 ------------------------------------------------------------------

      test 'date-only filters are days in the admin time zone; the API keeps UTC' do
        event = record('report.generated', occurred_at: Time.utc(2026, 10, 4, 12))

        Time.use_zone('Pacific/Auckland') do
          assert_includes log(from: '2026-10-05', to: '2026-10-05').relation, event
          assert_not_includes log(from: '2026-10-04', to: '2026-10-04').relation, event
          assert_equal({ 'from' => '2026-10-05' }, log(from: '2026-10-05').filters.to_h)
        end
        assert_includes PermissionForge::Audit::EventQuery.call({ from: '2026-10-04', to: '2026-10-04' }), event
        error = assert_raises(PermissionForge::Audit::EventQuery::Invalid) { log(from: '2026-02-30').relation }
        assert_equal [:from], error.errors.keys
      end

      test 'views of the log are left out of the default list, kept on request or when filtered for' do
        record('audit.viewed', data: { 'scope' => 'log' })
        record('report.generated')

        assert_not_includes log.relation.pluck(:event), 'audit.viewed'
        assert_includes log(views: '1').relation.pluck(:event), 'audit.viewed'
        assert_includes log(event: 'audit.viewed').relation.pluck(:event), 'audit.viewed'
        assert_includes log(category: 'admin').relation.pluck(:event), 'audit.viewed'
        assert_includes AuditLog.new({}, include_views: true).relation.pluck(:event), 'audit.viewed'
        assert_not log.include_views?
        assert_equal({ 'views' => '1' }, log(views: '1').link_params.to_h)
      end

      test 'export metadata names the time zone and that views of the log are included' do
        meta, = parse_csv(Exports::Events.call(log.relation, filters: { 'from' => '2026-10-05' },
                                                             time_zone: 'Pacific/Auckland').render(:csv))

        assert_equal 'Pacific/Auckland', meta['time_zone']
        assert_equal true, JSON.parse(meta['filters'])['include_views']
      end

      test 'known people come from a recent window' do
        old = create_user(name: 'Old Admin')
        record('report.generated', actor: old, occurred_at: 200.days.ago)
        record('report.generated', actor: @ana)

        people = AuditLog.known_people.to_h
        assert_includes people.keys, @ana.id.to_s
        assert_not_includes people.keys, old.id.to_s
      end

      test 'a value whose first non-space character starts a formula is neutralised' do
        assert_equal "' =1+1", Csv.cell(' =1+1')
        assert_equal %("'\n=1"), Csv.cell("\n=1")
        assert_equal "'  @SUM(A1)", Csv.cell('  @SUM(A1)')
        assert_equal 'a=1', Csv.cell('a=1')
      end

      test 'an edit newer than the last event (made while auditing was off) leaves the columns in charge' do
        PermissionForge.with_audit_actor(user: @ana) { @set.update!(description: 'by Ana') }
        event = LastChanges.new([@set])[@set]
        @set.update_columns(updated_at: event.occurred_at + 5.seconds, updated_by_id: @bo.id)

        assert_nil LastChanges.new([@set]).last_edit(@set)
        assert_equal event, LastChanges.new([@set])[@set]
        entry = AuditTrail.new.for_permission_set(@set).find { |e| e.type == 'permission_set' }
        assert_equal [nil, @bo.id.to_s], [entry.last_event, entry.editor_id]
      end

      test 'the person tab knows it was capped from the rows read, not the rows kept' do
        2.times { |i| PermissionForge.with_audit_actor(user: @bo) { create_permission_set(name: "Bo #{i}") } }
        PermissionForge::PermissionSet.where(name: ['Bo 0', 'Bo 1']).update_all(updated_by_id: @ana.id)
        trail = AuditTrail.new

        assert_empty trail.changes_by(@ana.id, limit: 2).fetch('permission_set', [])
        assert trail.capped?
      end

      # ---- lookups -------------------------------------------------------------------------

      test 'lookups find people, sets and a membership group once per page' do
        group = create_permission_set_group(name: 'Ops')
        PermissionForge.with_audit_actor(user: @ana) do
          PermissionForge::PermissionSetGroupUser.create!(user: @bo, permission_set_group: group)
        end
        event = assert_audit_event('group_membership.added')
        lookups = AuditLookups.new([event])

        assert_equal @bo, lookups.person(event.subject_user_id)
        assert_equal group, lookups.group(event)
        assert_nil lookups.permission_set(nil)
        assert_nil lookups.person('')
      end
    end
  end
end
