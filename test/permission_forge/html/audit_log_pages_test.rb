require_relative 'admin_test_case'
require_relative '../admin/csv_reading'

module PermissionForge
  module Html
    # The audit log in the admin: the filtered list and its pages, one event,
    # the exports, the timelines on the audit tabs, and the gate in front of
    # all of them (config.audit_log_authorization).
    class AuditLogPagesTest < AdminTestCase
      setup do
        @old_resolver = PermissionForge.configuration.current_user_resolver
        @admin = create_user(name: 'Ada Admin')
        admin = @admin
        PermissionForge.configuration.current_user_resolver = -> { admin }
      end

      teardown do
        PermissionForge.configuration.current_user_resolver = @old_resolver
      end

      def refuse_log
        PermissionForge.configuration.audit_log_authorization = ->(_controller) { false }
      end

      def assert_refusal_recorded(&)
        assert_difference(-> { refusals.count }, 1) do
          assert_no_difference(-> { PermissionForge::AuditEvent.where(event: %w[audit.viewed audit.exported]).count }, &)
        end
      end

      def refusals
        PermissionForge::AuditEvent.where(event: 'admin.auth_failed')
                                   .select { |event| event.data['reason'] == 'audit_log_not_authorized' }
      end

      def csv_export
        PermissionForge::Admin::CsvReading.export(response.body)
      end

      # ---- the log ---------------------------------------------------------------

      test 'the log lists events newest first with a sentence each, and links to them' do
        PermissionForge::Audit.correlate { delete pf("/assignments/#{@assignment.id}") }
        revoked = assert_audit_event('assignment.revoked', record_id: @assignment.id.to_s)

        get pf('/audit')

        assert_response :success
        assert_select 'h1', I18n.t('permission_forge.audit_events.index.title')
        assert_select 'nav.pf-sidebar a[href="/permission_forge/audit"]'
        assert_select ".pf-audit-event a[href='/permission_forge/audit/#{revoked.uuid}']", text: 'Ada Admin removed Sales rep from Ana Krasniqi.'
        times = css_select('.pf-audit-event time').map { |node| Time.iso8601(node['datetime']) }
        assert_equal times.sort.reverse, times
        assert_audit_event('audit.viewed', actor_id: @admin.id.to_s, data: { 'scope' => 'log' })
      end

      test 'filters narrow the log; every filter keeps its value in the form' do
        create_permission_set_user(user: @bo, permission_set: @set)
        other = create_permission_set(name: 'Other')
        create_permission_set_user(user: @bo, permission_set: other)

        get pf('/audit'), params: { event: 'assignment.granted', permission_set: @set.id, subject_user_id: @bo.id,
                                    from: 1.day.ago.to_date.iso8601, to: Date.current.iso8601 }

        assert_response :success
        assert_select '.pf-audit-event', 1
        assert_select '.pf-audit-event__sentence', text: /Bo Berisha/
        assert_select "select[name=event] option[selected][value='assignment.granted']"
        assert_select "select[name=permission_set] option[selected][value='#{@set.id}']"
        assert_select "input[name=subject_user_id][value='#{@bo.id}']"
        assert_select "a[href^='/permission_forge/audit.csv'][href*='event=assignment.granted']"
        recorded = assert_audit_event('audit.viewed', data: { 'scope' => 'log' })
        assert_equal 'assignment.granted', recorded.data['filters']['event']
      end

      test 'an invalid filter is a localized error on the page, not a 500' do
        PermissionForge::BUNDLED_LOCALES.each do |locale|
          get pf('/audit'), params: { from: '2026-02-30', event: 'no.such', locale: locale }

          assert_response :unprocessable_entity
          assert_select '#pf-audit-errors li', 2
          assert_select 'input[name=from][aria-invalid=true]'
          assert_no_missing_translations
        end
        get pf('/audit'), params: { from: '2026-02-30', record_id: '7', actor_id: %w[1 2], locale: 'en' }
        assert_select '#pf-audit-errors li', text: 'From: “2026-02-30” is not valid.'
        assert_select '#pf-audit-errors li', text: 'Record type is needed for this filter.'
        assert_select '#pf-audit-errors li', text: 'Actor (person id): this value is not valid.'
        get pf('/audit.csv'), params: { actor_id: %w[1 2] }
        assert_response :unprocessable_entity
      end

      test 'the log pages through everything, with page links' do
        53.times { |i| PermissionForge::Audit.record('report.generated', data: { 'n' => i }) }

        get pf('/audit'), params: { event: 'report.generated' }
        assert_select '.pf-audit-event', PermissionForge::Admin::AuditLog::PER_PAGE
        assert_select 'a[rel=next][href*="page=2"]'
        assert_match '1–50', response.body

        get pf('/audit'), params: { event: 'report.generated', page: 2 }
        assert_select '.pf-audit-event', 3
        assert_select 'a[rel=prev][href*="page=1"]'
        assert_select 'a[rel=next]', 0
      end

      test 'an event shows who, where, why, the record and the before and after' do
        @email.update!(mask_strategy: 'last4')
        PermissionForge::Audit.record('report.generated', reason: 'TCK-9', data: { 'report' => 'q3', 'rows' => [1, 2] })
        updated = assert_audit_event('resource_field.updated', record_id: @email.id.to_s)
        report = assert_audit_event('report.generated', reason: 'TCK-9')

        get pf("/audit/#{updated.uuid}")

        assert_response :success
        assert_select '.pf-audit-table tbody tr th', text: 'mask_strategy'
        assert_select '.pf-audit-table__before', text: /email/
        assert_select '.pf-audit-table__after', text: /last4/
        assert_select "a[href='/permission_forge/audit?correlation_id=#{updated.correlation_id}']"
        assert_select "a[href='/permission_forge/permission_sets/#{@set.id}']", text: 'Sales rep'

        get pf("/audit/#{report.id}")
        assert_select 'dd', text: 'TCK-9'
        assert_select '.pf-audit-table th', text: 'report'
        assert_select '.pf-audit-table td', text: '[1,2]'
        assert_audit_event('audit.viewed', data: { 'scope' => 'event', 'identifier' => report.id.to_s })

        assert_raises(ActionController::RoutingError) { get pf('/audit/no-such-event') }
      end

      test 'a deleted record shows its snapshot' do
        rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers')
        delete pf("/permission_sets/#{@set.id}/resources/Customer/rules/#{rule.id}"), params: { reason: 'cleanup' }
        destroyed = assert_audit_event('permission_set_rule.destroyed', record_id: rule.id.to_s, reason: 'cleanup')

        get pf("/audit/#{destroyed.uuid}")

        assert_select 'h1', text: /Ada Admin removed the record rule Own customers from Sales rep/
        assert_select '.pf-audit-table th', text: 'field_name'
        assert_select 'dd', text: 'cleanup'
      end

      test 'an event without a sentence of its own reads generically' do
        PermissionForge::Audit::EventCatalog.register('host.thing_happened', category: 'system')
        event = PermissionForge::Audit.record('host.thing_happened', data: { 'anything' => { 'nested' => true } })

        get pf("/audit/#{event.uuid}")
        assert_select 'h1', 'Ada Admin: host.thing_happened'
        assert_select '.pf-audit-table td', text: '{"nested":true}'

        get pf('/audit'), params: { event: 'host.thing_happened' }
        assert_select '.pf-audit-event__sentence', 'Ada Admin: host.thing_happened'
        assert_select 'select[name=event] option[value="host.thing_happened"]'
      ensure
        PermissionForge::Audit::EventCatalog.unregister('host.thing_happened')
      end

      test 'every catalogued event has a sentence in every bundled locale' do
        PermissionForge::Audit::EventCatalog.names.each do |name|
          PermissionForge::BUNDLED_LOCALES.each do |locale|
            assert I18n.exists?("permission_forge.audit_log.sentences.#{name}", locale), "#{locale}: #{name}"
          end
        end
      end

      # ---- exports ---------------------------------------------------------------

      test 'the CSV export has every column, a metadata block and every row, past one page' do
        53.times { |i| PermissionForge::Audit.record('report.generated', reason: (i.zero? ? '=1+1' : nil), data: { 'n' => i }) }

        get pf('/audit.csv'), params: { event: 'report.generated' }

        assert_response :success
        assert_equal 'text/csv', response.media_type
        assert_match(/attachment; filename="permission-forge-audit-log-\d{8}T\d{6}Z\.csv"/, response.headers['Content-Disposition'])
        meta, header, rows = csv_export
        assert_equal ['audit_events', 'Ada Admin', 'user', @admin.id.to_s, '53'],
                     meta.values_at('export', 'exported_by', 'exported_by_type', 'exported_by_id', 'row_count')
        assert_equal({ 'event' => 'report.generated', 'include_views' => true }, JSON.parse(meta['filters']))
        assert_equal PermissionForge::Admin::Exports::Events.columns, header
        assert_equal 53, rows.size
        assert_equal "'=1+1", rows.first[header.index('reason')]
        assert_audit_event('audit.exported', data: { 'scope' => 'log', 'format' => 'csv' })
      end

      test 'the JSON export' do
        get pf('/audit.json'), params: { permission_set: @set.id }

        assert_response :success
        body = JSON.parse(response.body)
        assert_equal body['data'].size, body['meta']['row_count']
        assert(body['data'].all? { |row| row['permission_set_id'] == @set.id })
        assert_audit_event('audit.exported', data: { 'scope' => 'log', 'format' => 'json' })
      end

      test 'who holds what, from the people page and the log' do
        get pf('/people')
        assert_select "a[href='/permission_forge/audit/holdings.csv']"

        get pf('/audit/holdings.csv')

        assert_response :success
        meta, header, rows = csv_export
        assert_equal 'holdings', meta['export']
        assert_equal PermissionForge::Admin::Exports::Holdings::COLUMNS, header
        row = rows.map { |r| header.zip(r).to_h }.find { |r| r['assignment_id'] == @assignment.id.to_s }
        assert_equal ['Ana Krasniqi', 'Sales rep'], row.values_at('person', 'permission_set')
        assert_audit_event('audit.exported', data: { 'scope' => 'holdings', 'format' => 'csv' })

        get pf('/audit/holdings')
        assert_response :not_acceptable
      end

      # ---- timelines -------------------------------------------------------------

      test 'the person audit tab: events about and by the person, paged, linked to the log' do
        delete pf("/assignments/#{@assignment.id}")
        about = PermissionForge::AuditEvent.where(subject_user_id: @ana.id.to_s).count

        get pf("/people/#{@ana.id}"), params: { tab: 'audit' }

        assert_response :success
        assert_select '.pf-audit-event', [about, 20].min
        assert_select '.pf-audit-event__sentence', text: 'Ada Admin removed Sales rep from Ana Krasniqi.'
        assert_select "a[href='/permission_forge/audit?subject_user_id=#{@ana.id}']"
        assert_select "a[href='/permission_forge/audit?actor_id=#{@ana.id}&actor_type=user']"
        assert_no_match 'pf-preview', response.body

        get pf("/people/#{@admin.id}"), params: { tab: 'audit' }
        assert_select '.pf-audit-event__sentence', text: 'Ada Admin removed Sales rep from Ana Krasniqi.'
      end

      test 'the Permission Set audit tab shows its timeline with pages' do
        22.times { |i| @set.update!(description: "v#{i}") }

        get pf("/permission_sets/#{@set.id}"), params: { tab: 'audit' }
        assert_select '.pf-audit-event', 20
        assert_select "a[href='/permission_forge/audit?permission_set=#{@set.id}']"
        assert_select "a[rel=next][href*='tab=audit'][href*='page=2']"

        total = PermissionForge::AuditEvent.where(permission_set_id: @set.id).where.not(event: 'audit.viewed').count
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'audit', page: 2 }
        assert_select '.pf-audit-event', total - 20
      end

      # ---- the gate --------------------------------------------------------------

      test 'refused: every audit page and export answers 403, records the refusal and no view' do
        refuse_log
        event = PermissionForge::AuditEvent.last

        [['/audit', :html], ['/audit.csv', :csv], ['/audit.json', :json], ["/audit/#{event.uuid}", :html],
         ['/audit/holdings.csv', :csv], ["/people/#{@ana.id}?tab=audit", :html], ["/people/#{@ana.id}.csv", :csv],
         ["/permission_sets/#{@set.id}?tab=audit", :html], ["/permission_sets/#{@set.id}.csv?tab=audit", :csv]].each do |path, kind|
          assert_refusal_recorded { get pf(path) }

          assert_response :forbidden, path
          if kind == :html
            assert_select '.pf-banner--block', text: /#{I18n.t('permission_forge.audit_log.refused.title')}/
          else
            assert_empty response.body, path
          end
        end
        assert_equal @admin.id.to_s, refusals.last.actor_id
      end

      test 'the other tabs and pages need no audit permission' do
        refuse_log

        assert_no_difference(-> { refusals.count }) do
          get pf("/people/#{@ana.id}")
          assert_response :success
          get pf("/permission_sets/#{@set.id}")
          assert_response :success
        end
      end

      test 'only an exact true opens the log; a raising hook refuses' do
        PermissionForge.configuration.audit_log_authorization = ->(_controller) { 'yes' }
        get pf('/audit')
        assert_response :forbidden

        PermissionForge.configuration.audit_log_authorization = ->(_controller) { raise 'boom' }
        get pf('/audit')
        assert_response :forbidden

        PermissionForge.configuration.audit_log_authorization = ->(controller) { controller.is_a?(ActionController::Base) }
        get pf('/audit')
        assert_response :success
      end

      # ---- review round 1 --------------------------------------------------------------

      test 'the log filters days in the admin time zone and says which' do
        old = Time.zone_default
        # use_zone restores the zone it read on entry, so enter it before
        # changing the default: otherwise Auckland outlives the test.
        Time.use_zone('Pacific/Auckland') do
          Time.zone_default = ActiveSupport::TimeZone['Pacific/Auckland']
          check_local_days
          get pf('/audit.csv'), params: { from: '2026-10-05' }
        ensure
          Time.zone_default = old
        end
        meta, = csv_export
        assert_equal ['Pacific/Auckland', '2026-10-05'], [meta['time_zone'], JSON.parse(meta['filters'])['from']]
      end

      def check_local_days
        event = PermissionForge::Audit.record('report.generated', occurred_at: Time.utc(2026, 10, 4, 12))

        get pf('/audit'), params: { from: '2026-10-05', to: '2026-10-05' }
        assert_select ".pf-audit-event a[href='/permission_forge/audit/#{event.uuid}']"
        assert_match 'Pacific/Auckland', css_select('.pf-audit-filters').text

        get pf('/audit'), params: { from: '2026-10-04', to: '2026-10-04' }
        assert_select ".pf-audit-event a[href='/permission_forge/audit/#{event.uuid}']", 0
      end

      test 'an event key with a NUL byte or longer than a column is not found, without asking the database' do
        ["a\u0000b", 'x' * 256].each do |key|
          assert_raises(ActionController::RoutingError) { get pf("/audit/#{CGI.escape(key)}") }
        end
      end

      test 'views of the log are hidden from the list and the timelines unless asked for' do
        get pf('/audit')
        get pf('/audit')
        assert_select '.pf-audit-event .pf-mono-key', text: 'audit.viewed', count: 0
        assert_select 'input[type=checkbox][name=views][value="1"]:not([checked])'
        assert_select '.pf-audit-views-note'

        get pf('/audit'), params: { views: '1' }
        assert_select '.pf-audit-event .pf-mono-key', text: 'audit.viewed', minimum: 1
        assert_select 'input[type=checkbox][name=views][checked]'

        get pf('/audit'), params: { event: 'audit.viewed' }
        assert_select '.pf-audit-event .pf-mono-key', text: 'audit.viewed', minimum: 1

        get pf("/permission_sets/#{@set.id}"), params: { tab: 'audit' }
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'audit' }
        assert_select '.pf-audit-event .pf-mono-key', text: 'audit.viewed', count: 0
        assert_select "a[href*='views=1'][href*='tab=audit']"
        get pf("/permission_sets/#{@set.id}"), params: { tab: 'audit', views: '1' }
        assert_select '.pf-audit-event .pf-mono-key', text: 'audit.viewed', minimum: 1

        get pf('/audit.csv')
        meta, header, rows = csv_export
        assert_includes rows.map { |row| row[header.index('event')] }, 'audit.viewed'
        assert_equal true, JSON.parse(meta['filters'])['include_views']
      end

      test 'the error page offers no export and keeps the record filters visible' do
        get pf('/audit'), params: { record_id: '7', from: 'nope' }

        assert_response :unprocessable_entity
        assert_select "a[href*='audit.csv']", 0
        assert_select "a[href*='audit.json']", 0
        assert_select 'input[name=record_type][aria-invalid=true]'
        assert_select 'datalist#pf-audit-people', 0
      end

      test 'footers ask the audit log once per page, and not at all while the trail is off' do
        PermissionForge.configuration.audit_trail_enabled = true
        11.times { |i| create_permission_set_rule(permission_set: @set, resource: @resource, name: "Rule #{i}") }

        assert_operator audit_selects { get pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules") }, :<=, 4
        assert_select '.pf-audit-footer', minimum: 12

        PermissionForge.configuration.audit_trail_enabled = false
        assert_equal(0, audit_selects { get pf("/permission_sets/#{@set.id}/resources/Customer?tab=rules") })
      end

      def audit_selects(&)
        table = PermissionForge::AuditEvent.table_name
        count = 0
        counter = lambda { |*, payload|
          count += 1 if payload[:sql].start_with?('SELECT') && payload[:sql].include?(table) && !payload[:sql].include?('sqlite_master')
        }
        ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
        count
      end

      test 'group member changes take a reason too' do
        group = create_permission_set_group(name: 'Ops')
        PermissionForge::PermissionSetGroupUser.create!(user: @bo, permission_set_group: group)

        get pf("/groups/#{group.id}")

        assert_select "form[action$='/members'] details.pf-reason input[name=reason]"
        assert_select "form[action*='/members/'] details.pf-reason input[name=reason]"
      end

      test 'the set and person CSVs are the audit records, gated, and never stored by a cache' do
        get pf("/permission_sets/#{@set.id}.csv")
        assert_response :success
        assert_equal 'text/csv', response.media_type
        assert_equal 'no-store', response.headers['Cache-Control']

        get pf("/permission_sets/#{@set.id}.csv"), params: { tab: 'assignments' }
        assert_response :success
        assert_equal 'no-store', response.headers['Cache-Control']

        get pf("/people/#{@ana.id}.csv")
        assert_response :success
        assert_equal 'no-store', response.headers['Cache-Control']

        refuse_log
        assert_refusal_recorded { get pf("/permission_sets/#{@set.id}.csv") }
        assert_response :forbidden
      end

      # ---- auditing off ------------------------------------------------------------

      test 'auditing off: the log says so and Home asks for attention' do
        PermissionForge.configuration.audit_events = false

        get pf('/audit')
        assert_select '.pf-banner--warn', text: /#{I18n.t('permission_forge.audit_log.off.title')}/

        get pf('/')
        assert_select '#pf-card-audit', I18n.t('permission_forge.home.audit_card.title')
        assert_match I18n.t('permission_forge.home.audit_card.off'), response.body
      end

      test 'a missing audit table: Home names the upgrade, the log is empty' do
        original = PermissionForge::Admin::AuditLog.method(:table?)
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?) { false }

        get pf('/')
        assert_match I18n.t('permission_forge.home.audit_card.missing_table'), response.body
        assert_match 'permission_forge:upgrade', response.body
        assert_equal [:missing_table], PermissionForge::Admin::AttentionItems.new.audit_findings
      ensure
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?, original)
      end

      test 'audit_events true without the table: every page warns that changes fail' do
        original = PermissionForge::Admin::AuditLog.method(:table?)
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?) { false }
        PermissionForge.configuration.audit_events = true

        get pf('/audit')
        assert_select '.pf-banner--warn', text: /#{Regexp.escape(I18n.t('permission_forge.audit_log.off.failing'))}/

        get pf('/')
        assert_match I18n.t('permission_forge.home.audit_card.failing'), response.body
        assert_match 'permission_forge:upgrade', response.body
        assert_equal [:failing], PermissionForge::Admin::AttentionItems.new.audit_findings

        get pf('/settings?focus=audit_events')
        assert_match I18n.t('permission_forge.settings.risks.audit_events'), CGI.unescapeHTML(response.body)
        assert_no_match I18n.t('permission_forge.settings.oks.audit_events'), response.body

        PermissionForge.configuration.audit_change_failure_strategy = :report
        assert_equal [:missing_table], PermissionForge::Admin::AttentionItems.new.audit_findings
      ensure
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?, original)
      end

      test 'audit_events false without the table: the note says recording is switched off' do
        original = PermissionForge::Admin::AuditLog.method(:table?)
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?) { false }
        PermissionForge.configuration.audit_events = false

        get pf('/audit')
        assert_match I18n.t('permission_forge.audit_log.off.disabled'), response.body
        assert_no_match I18n.t('permission_forge.audit_log.off.missing_table'), response.body
        assert_equal [:off], PermissionForge::Admin::AttentionItems.new.audit_findings
      ensure
        replace_singleton_method(PermissionForge::Admin::AuditLog, :table?, original)
      end
    end
  end
end
