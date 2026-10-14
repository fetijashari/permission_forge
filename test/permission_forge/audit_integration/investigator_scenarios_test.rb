# frozen_string_literal: true

require 'test_helper'
require 'rake'
require_relative '../audit/request_audit_test_helper'
require_relative '../admin/csv_reading'

module PermissionForge
  module AuditIntegration
    # The twelve questions an investigator asks of the audit log
    # (docs/audit-log.md), one scenario each.
    #
    # Every scenario first makes the history the way it happens in life:
    # admins working in the admin screens — signed in (current_user_resolver)
    # or through the shared HTTP Basic login — the JSON API, and the services
    # and rake tasks that run unattended (expiry clean-up, erasure). Then it
    # answers the question ONLY from what an investigator can reach: the Audit
    # log page (`/audit?…`), its exports (`/audit.csv`, `/audit.json`,
    # `/audit/holdings.csv`), the event page, `GET /api/audit_events`, and the
    # People page to look a person up. Never from the models.
    #
    # Every scenario also says why it fails on 0.12.2. Common to all: 0.12.2
    # has no audit table and no route to read one (`/audit`, `/audit.csv`,
    # `/api/audit_events` are RoutingErrors); it kept only `created_by_id` /
    # `updated_by_id` on the live row, overwritten by the next edit, blank for
    # an HTTP Basic admin, an API client, a job or rake, and gone with the row.
    class InvestigatorScenariosTest < ActionDispatch::IntegrationTest
      include PermissionForge::Audit::RequestAuditTestHelper

      BASIC_USER = 'ops-admin'
      BASIC_PASSWORD = 'shared-s3cret'
      BASIC_NAME = 'ops-admin (password prompt)'
      FLAGS = %w[read_access create_access edit_access delete_access view_all modify_all].freeze
      # The columns of the log's exports and API rows (docs: admin audit log exports).
      EXPORT_COLUMNS = %w[id uuid occurred_at event category actor_type actor_id actor_label source record_type record_id
                          record_uuid record_label permission_set_id permission_set_uuid subject_user_id data reason request_id
                          ip correlation_id created_at].freeze

      # Replays exported events into the records they describe, as of a time:
      # a creation's snapshot, then each update's "to" values, until a removal.
      class EventReplay
        CREATED = /\.(created|granted|added)\z/
        REMOVED = /\.(destroyed|revoked|removed)\z/

        def initialize(rows)
          @rows = rows.sort_by { |row| [Time.iso8601(row['occurred_at']), row['id']] }
        end

        # @return [Hash{[record_type, record_id] => Hash}]
        def as_of(time)
          @rows.select { |row| Time.iso8601(row['occurred_at']) <= time }.each_with_object({}) { |row, state| apply(state, row) }
        end

        private

        def apply(state, row)
          key = [row['record_type'], row['record_id']]
          data = row['data'] || {}
          case row['event']
          when CREATED then state[key] = data['snapshot'].dup
          when REMOVED then state.delete(key)
          else update(state[key] ||= {}, data['changes'])
          end
        end

        def update(record, changes)
          (changes || {}).each { |attribute, (_from, to)| record[attribute] = to }
        end
      end

      # What replayed records allowed: per Resource the flags that were on,
      # the level of email and name, and the rules.
      class Allowed
        def self.call(state) = new(state).summary

        def initialize(state)
          @by_type = state.group_by { |(type, _), _| type.delete_prefix('PermissionForge::') }
                          .transform_values { |pairs| pairs.map(&:last) }
        end

        def summary
          records('Resource').to_h { |resource| [resource['name'], resource_summary(resource)] }
        end

        private

        def records(type) = @by_type.fetch(type, [])

        def children(type, resource)
          records(type).select { |row| row['resource_id'] == resource['id'] }
        end

        def resource_summary(resource)
          { 'flags' => FLAGS.select { |flag| resource[flag] },
            'fields' => children('ResourceField', resource).to_h { |field| [field['name'], level(field)] }.slice('email', 'name'),
            'rules' => children('PermissionSetRule', resource).map { |rule| rule['name'] } }
        end

        def level(field)
          return 'hidden' unless field['read_access']
          return 'masked' if field['mask_access']

          field['edit_access'] ? 'edit' : 'read'
        end
      end

      # The gem's rake tasks, loaded once per process (the rake tasks test
      # loads the same files; a second load would reset their coverage).
      def self.rake_application
        return PermissionForge::AuditRakeTasksTest.rake_application if defined?(PermissionForge::AuditRakeTasksTest)

        @rake_application ||= begin
          previous = Rake.application
          app = Rake.application = Rake::Application.new
          Rake::Task.define_task(:environment)
          load PermissionForge::Engine.root.join('lib/tasks/permission_forge_expiration.rake').to_s
          Rake.application = previous
          app
        end
      end

      setup do
        @ivy = create_user(name: 'Ivy Investigator', email: 'ivy@acme.test')
        @ada = create_user(name: 'Ada Admin', email: 'ada@acme.test')
        @ben = create_user(name: 'Ben Builder', email: 'ben@acme.test')
        @ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = create_user(name: 'Bo Berisha', email: 'bo@acme.test')
        @headers = {}
        sign_in(@ivy)
      end

      # --- 1 ---------------------------------------------------------------------------

      # 0.12.2: the assignment row says created_by_id nil (the Basic login is
      # no user) and expires_at is the end date of the LATER change; the
      # original end date and the grantor were never stored anywhere.
      test '1. who granted access to Payroll, and with what end date' do
        payroll = travel_to(Time.zone.local(2026, 3, 1)) { make_set('Payroll') }
        travel_to Time.zone.local(2026, 3, 2, 9, 15) do
          as_basic do
            admin(:post, '/assignments', user_id: @ana.id, set_ids: [payroll], expiry: 'custom', custom_date: '2026-12-31',
                                         reason: 'HR-311 new payroll clerk')
            admin(:post, '/assignments', user_id: @bo.id, set_ids: [payroll], expiry: 'never') # someone else, same set
          end
        end
        travel_to(Time.zone.local(2026, 4, 1, 10)) { as(@ada) { admin(:patch, "/assignments/#{assignment_id(@ana, payroll)}", expiry: 'eom') } }

        ana = person_id('Ana Krasniqi')
        set = permission_set_filter_value('Payroll')
        grant = log_rows(event: 'assignment.granted', subject_user_id: ana, permission_set: set).sole
        assert_equal "#{BASIC_NAME} gave Ana Krasniqi the Permission Set Payroll.", grant['sentence']
        assert_equal Time.zone.local(2026, 3, 2, 9, 15), grant['at']

        page = event_page(grant['uuid'])
        assert_equal Date.new(2026, 12, 31), local_date(page['snapshot']['expires_at']), 'the end date given at the grant'
        assert_equal 'HR-311 new payroll clerk', page['facts']['Reason']
        assert_match(/\A#{Regexp.escape(BASIC_NAME)} · Password prompt/, page['facts']['Actor'])

        api = api_events(event: 'assignment.granted', subject_user_id: ana, permission_set: set).sole
        assert_equal ['basic_auth', nil, BASIC_USER, 'admin_ui'], api.values_at('actor_type', 'actor_id', 'actor_label', 'source')
        changed = api_events(event: 'assignment.changed', subject_user_id: ana, permission_set: set).sole
        assert_equal([Date.new(2026, 12, 31), Date.new(2026, 4, 30)], changed.dig('data', 'changes', 'expires_at').map { |value| local_date(value) })
        assert_equal 'Ada Admin', changed['actor_label']
      end

      # --- 2 ---------------------------------------------------------------------------

      # 0.12.2: a removal is a hard delete; nothing is left to say it existed,
      # let alone who removed it (twice) and when.
      test '2. who removed Ana from Payroll, and when' do
        payroll = travel_to(Time.zone.local(2026, 4, 1)) do
          make_set('Payroll').tap { |set| as(@ada) { [@ana, @bo].each { |person| assign(person, set) } } }
        end
        travel_to Time.zone.local(2026, 5, 10, 14) do
          as(@ben) { admin(:delete, "/assignments/#{assignment_id(@bo, payroll)}") } # someone else, same set
          as(@ben) { admin(:delete, "/assignments/#{assignment_id(@ana, payroll)}", reason: 'left the payroll team') }
          undo = flash[:pf_undo]
          as(@ada) { admin(:post, undo[:path].delete_prefix(ROOT), **undo[:params].symbolize_keys) } # the toast's Undo
        end
        travel_to Time.zone.local(2026, 6, 1, 8, 30) do
          as_basic { admin(:delete, "/assignments/#{assignment_id(@ana, payroll)}") }
        end

        ana = person_id('Ana Krasniqi')
        removals = log_rows(event: 'assignment.revoked', subject_user_id: ana, permission_set: permission_set_filter_value('Payroll'))
        assert_equal(["#{BASIC_NAME} removed Payroll from Ana Krasniqi.", 'Ben Builder removed Payroll from Ana Krasniqi.'],
                     removals.map { |row| row['sentence'] })
        assert_equal([Time.zone.local(2026, 6, 1, 8, 30), Time.zone.local(2026, 5, 10, 14)], removals.map { |row| row['at'] })
        assert_equal([nil, 'Reason: left the payroll team'], removals.map { |row| row['reason'] })

        _, rows = csv_export(subject_user_id: ana, event: 'assignment.granted,assignment.revoked')
        assert_equal([['assignment.granted', 'Ada Admin'], ['assignment.revoked', 'Ben Builder'], ['assignment.granted', 'Ada Admin'],
                      ['assignment.revoked', BASIC_USER]], rows.map { |row| row.values_at('event', 'actor_label') })
        assert_empty(holdings.select { |row| row['person'] == 'Ana Krasniqi' && row['permission_set'] == 'Payroll' })
      end

      # --- 3 ---------------------------------------------------------------------------

      # 0.12.2: only today's rows exist. The mask on email in March, Edit
      # turned on in April and off in June, and the rule that existed between
      # May 20 and June 5 cannot be recovered: updates overwrote the columns
      # and the rule row was deleted.
      test '3. what the Support Permission Set allowed on a past date' do
        build_support_history

        set = permission_set_filter_value('Support')
        history = json_export(permission_set: set)
        assert_equal history['data'].size, history['meta']['row_count']
        rows = history['data']

        assert_equal({ 'Customer' => { 'flags' => %w[read_access], 'fields' => { 'email' => 'read', 'name' => 'read' },
                                       'rules' => [] } },
                     allowed_at(rows, as_of: Time.zone.local(2026, 3, 10)))
        may_first = { 'Customer' => { 'flags' => %w[read_access edit_access], 'fields' => { 'email' => 'masked', 'name' => 'edit' },
                                      'rules' => [] } }
        assert_equal may_first, allowed_at(rows, as_of: Time.zone.local(2026, 5, 1).end_of_day)
        assert_equal(['Acme only'], allowed_at(rows, as_of: Time.zone.local(2026, 6, 1))['Customer']['rules'])
        assert_equal({ 'Customer' => { 'flags' => %w[read_access], 'fields' => { 'email' => 'read', 'name' => 'read' },
                                       'rules' => [] } },
                     allowed_at(rows, as_of: Time.current))

        # The same answer from the app's own date filter: everything up to and including May 1.
        assert_equal may_first, allowed_at(json_export(permission_set: set, to: '2026-05-01')['data'], as_of: Time.current)
      end

      # --- 4 ---------------------------------------------------------------------------

      # 0.12.2: the field and the resource keep only their current values;
      # updated_by was blank after the Basic-login edit and then overwritten
      # by Ada's label edit, so neither the person nor the previous value is known.
      test '4. who unmasked a field or turned on View All, and what it was before' do
        sales = nil
        travel_to(Time.zone.local(2026, 2, 1, 9)) do
          sales = make_set('Sales rep')
          as(@ada) do
            admin(:post, "/permission_sets/#{sales}/resources", model_name: 'Customer', preset: 'read')
            admin(:patch, field_path(sales, 'email'), field: { level: 'masked', mask_strategy: 'email' })
          end
        end
        travel_to(Time.zone.local(2026, 3, 3, 16)) { as_basic { admin(:patch, field_path(sales, 'email'), field: { level: 'read' }) } }
        travel_to Time.zone.local(2026, 3, 4, 11) do
          as(@ben) { admin(:patch, "/permission_sets/#{sales}/apply", pf: { resources: { resource_id(sales) => { view_all: '1' } } }) }
        end
        travel_to(Time.zone.local(2026, 3, 20)) { as(@ada) { admin(:patch, field_path(sales, 'email'), field: { label: 'E-mail' }) } }

        set = permission_set_filter_value('Sales rep')
        pages = log_rows(event: 'resource_field.updated', permission_set: set).map { |row| [row, event_page(row['uuid'])] }
        row, = pages.find { |_, page| page['changes']['mask_access'] == %w[Yes No] } # before: masked; after: not
        assert_equal "#{BASIC_NAME} changed the field Customer.email in Sales rep.", row['sentence']
        assert_equal Time.zone.local(2026, 3, 3, 16), row['at']

        view_all = log_rows(event: 'resource.updated', permission_set: set).sole
        assert_equal 'Ben Builder changed the resource Customer in Sales rep.', view_all['sentence']
        assert_equal %w[No Yes], event_page(view_all['uuid'])['changes']['view_all']

        _, rows = csv_export(permission_set: set, event: 'resource_field.updated,resource.updated')
        unmaskers = rows.select { |r| r.dig('data', 'changes', 'mask_access') == [true, false] }
        view_all_on = rows.select { |r| r.dig('data', 'changes', 'view_all') == [false, true] }
        assert_equal([[BASIC_USER, 'basic_auth']], unmaskers.map { |r| r.values_at('actor_label', 'actor_type') })
        assert_equal([['Ben Builder', 'user']], view_all_on.map { |r| r.values_at('actor_label', 'actor_type') })
      end

      # --- 5 ---------------------------------------------------------------------------

      # 0.12.2: destroy! removed the rule, the set and every cascaded row;
      # nothing records who did it or what the rule filtered on, what the set
      # granted, or that Bo held it.
      test '5. who deleted a rule and a whole Permission Set, and what they contained' do
        contractors = nil
        travel_to(Time.zone.local(2026, 3, 1)) { contractors = make_set('Contractors') }
        travel_to(Time.zone.local(2026, 3, 2)) { build_contractors(contractors) }
        acme_only = PermissionForge::PermissionSetRule.find_by!(name: 'Acme only').id
        travel_to Time.zone.local(2026, 4, 2, 15) do
          as(@ben) { admin(:delete, "/permission_sets/#{contractors}/resources/Customer/rules/#{acme_only}", reason: 'TCK-5 obsolete') }
        end
        travel_to(Time.zone.local(2026, 4, 3, 9)) { as(@ada) { admin(:delete, "/permission_sets/#{contractors}", reason: 'TCK-6 project ended') } }

        rule = log_rows(event: 'permission_set_rule.destroyed').find { |row| row['sentence'].include?('Acme only') }
        assert_match(/\ABen Builder removed the record rule Acme only from /, rule['sentence'])
        assert_equal Time.zone.local(2026, 4, 2, 15), rule['at']
        page = event_page(rule['uuid'])
        assert_equal %w[domain equal acme.test], page['snapshot'].values_at('field_name', 'operator', 'field_value')
        assert_equal 'TCK-5 obsolete', page['facts']['Reason']

        deleted = log_rows(event: 'permission_set.destroyed').sole
        assert_equal 'Ada Admin deleted the Permission Set Contractors.', deleted['sentence']
        set_page = event_page(deleted['uuid'])
        assert_equal 'TCK-6 project ended', set_page['facts']['Reason']
        action = set_page['facts']['Action'].split.first
        export = json_export(correlation_id: action) # "All events of this action"
        assert_equal EXPORT_COLUMNS, export['columns']
        contents = export['data']
        assert(contents.all? { |row| row.keys == EXPORT_COLUMNS })
        assert_operator contents.size, :>, 5
        assert_equal [action], contents.map { |row| row['correlation_id'] }.uniq, 'the cascade is one action'
        removed = contents.to_h { |row| [row['record_label'], row['event']] }
        assert_equal({ 'Contractors' => 'permission_set.destroyed', 'Customer' => 'resource.destroyed',
                       'Customer.email' => 'resource_field.destroyed', 'Named' => 'permission_set_rule.destroyed',
                       'Bo Berisha' => 'assignment.revoked' }, removed.slice('Contractors', 'Customer', 'Customer.email', 'Named', 'Bo Berisha'))
        email = contents.find { |row| row['record_label'] == 'Customer.email' }.dig('data', 'snapshot')
        assert_equal [true, true, 'email'], email.values_at('read_access', 'mask_access', 'mask_strategy')
        assert(contents.all? { |row| row['actor_label'] == 'Ada Admin' && row['reason'] == 'TCK-6 project ended' })
      end

      # --- 6 ---------------------------------------------------------------------------

      # 0.12.2: there is no file to produce. With the events, the quarter must
      # be the quarter in the app's time zone: Pacific/Auckland moves from
      # +12:00 to +13:00 on 27 September, and two of these changes fall on a
      # different UTC date than their local one.
      test '6. every access change in a quarter, as one file, in the app time zone' do
        with_zone('Pacific/Auckland') do
          quarter = make_set('Quarter set')
          people = { before: @ana, first: @bo, middle: @ivy, last: @ada, after: @ben }
          moments = { before: Time.utc(2026, 6, 30, 11, 30),  # 30 Jun 23:30 NZST: Q2
                      first: Time.utc(2026, 6, 30, 12, 30),   # 1 Jul 00:30 NZST: Q3, a June date in UTC
                      middle: Time.utc(2026, 8, 14, 22),      # 15 Aug 10:00 NZST
                      last: Time.utc(2026, 9, 30, 10, 30),    # 30 Sep 23:30 NZDT: Q3
                      after: Time.utc(2026, 9, 30, 11, 30) }  # 1 Oct 00:30 NZDT: Q4, a September date in UTC
          moments.each do |key, moment|
            travel_to(moment) { as(@ben) { admin(:post, '/assignments', user_id: people[key].id, set_ids: [quarter], expiry: 'never') } }
          end
          travel_to(Time.utc(2026, 8, 1)) { as(@ada) { admin(:get, "/people/#{@ana.id}", tab: 'effective') } } # not a change

          meta, rows = csv_export(from: '2026-07-01', to: '2026-09-30', category: 'change')

          assert_equal 'Pacific/Auckland', meta['time_zone']
          assert_equal rows.size.to_s, meta['row_count']
          assert_equal %w[change], rows.map { |row| row['category'] }.uniq
          granted = rows.select { |row| row['event'] == 'assignment.granted' }
          assert_equal([@bo, @ivy, @ada].map { |person| person.id.to_s }, granted.map { |row| row['subject_user_id'] })
          assert_equal(moments.values_at(:first, :middle, :last), granted.map { |row| Time.iso8601(row['occurred_at']) })
        end
      end

      # --- 7 ---------------------------------------------------------------------------

      # 0.12.2: viewing a person's effective access and exporting were not
      # recorded at all (there was no log to export).
      test '7. who looked at effective access, and who exported or read the log' do
        travel_to(Time.zone.local(2026, 7, 1, 9)) { as(@ada) { admin(:get, "/people/#{@ana.id}", tab: 'effective') } }
        travel_to(Time.zone.local(2026, 7, 1, 10)) { as_basic { admin(:get, "/people/#{@bo.id}", tab: 'effective') } }
        travel_to Time.zone.local(2026, 7, 2, 18) do
          as(@ben) do
            admin(:get, '/audit.csv', subject_user_id: @ana.id)
            admin(:get, '/audit.json')
            admin(:get, '/api/audit_events', event: 'assignment.granted')
          end
        end

        looked = log_rows(event: 'admin.effective_access_viewed')
        assert_equal(["#{BASIC_NAME} looked at the effective access of Bo Berisha.",
                      'Ada Admin looked at the effective access of Ana Krasniqi.'], looked.map { |row| row['sentence'] })
        assert_equal([Time.zone.local(2026, 7, 1, 10), Time.zone.local(2026, 7, 1, 9)], looked.map { |row| row['at'] })

        exports = log_rows(event: 'audit.exported')
        assert_equal(['Ben Builder exported audit records.'] * 2, exports.map { |row| row['sentence'] })
        _, rows = csv_export(event: 'audit.exported')
        assert_equal([['Ben Builder', 'csv', @ana.id.to_s], ['Ben Builder', 'json', nil]],
                     rows.map { |row| [row['actor_label'], row.dig('data', 'format'), row.dig('data', 'filters', 'subject_user_id')] })
        _, again = csv_export(event: 'audit.exported')
        assert_equal ['Ivy Investigator', 'csv'], [again.last['actor_label'], again.last.dig('data', 'format')],
                     "the investigator's own export is in the log too"

        api_reads = api_events(event: 'audit.viewed').select { |row| row.dig('data', 'scope') == 'api' }
        assert_equal ['Ben Builder', 'api'], api_reads.find { |row| row['actor_label'] == 'Ben Builder' }.values_at('actor_label', 'source')
      end

      # --- 8 ---------------------------------------------------------------------------

      # 0.12.2: who COULD read follows only from today's rows (no history of
      # how a field came to be unmasked), and nobody can say who DID read:
      # field reads were never recorded (on_field_filtered named no record).
      test '8. who could read customer emails unmasked, and who did' do
        build_email_access
        customer = create_customer(name: 'Acme', email: 'john@acme.test', domain: 'acme.test')
        with_runtime_events(%i[denied field_read]) do
          [@ana, @bo].each { |reader| as_host_user(reader) { Customer.find_by(id: customer.id).email } }
        end

        state = EventReplay.new(json_export(category: 'change')['data']).as_of(Time.current)
        readable_sets = state.values.select { |row| row['name'] == 'email' && row.key?('mask_access') }
                             .reject { |field| field['mask_access'] || !field['read_access'] }
                             .map { |field| state.dig(['PermissionForge::Resource', field['resource_id'].to_s], 'permission_set_id').to_s }
        could = holdings.select { |row| readable_sets.include?(row['permission_set_id']) && row['expired'] == 'false' }
        assert_equal ['Ana Krasniqi'], could.map { |row| row['person'] }, 'Cat held Billing too, but it ended'

        reads = api_events(event: 'field.access', record_type: 'Customer', record_id: customer.id)
        plain = reads.select { |row| row.dig('data', 'passed_fields').include?('email') }
        assert_equal ['Ana Krasniqi'], plain.map { |row| row['actor_label'] }.uniq, 'the event names the field read in the clear'
        masked = reads.select { |row| row.dig('data', 'masked').include?('email') }
        assert_equal ['Bo Berisha'], masked.map { |row| row['actor_label'] }.uniq
        assert_empty plain & masked
        sentences = log_rows(event: 'field.access').map { |row| row['sentence'] }
        assert_includes sentences, "Ana Krasniqi read Customer ##{customer.id}."
        assert_includes sentences, "Bo Berisha read Customer ##{customer.id} with these fields hidden or masked: email."
        assert(reads.all? { |row| row['source'] == 'runtime' && row['record_id'] == customer.id.to_s })
      end

      # --- 9 ---------------------------------------------------------------------------

      # 0.12.2: "Keep" was a touch of updated_at: no reviewer, and Ben's later
      # end-date change moved updated_at again, so even the review date was lost.
      test '9. who reviewed which assignment, and when (Keep)' do
        sales = nil
        on('2025-12-01 09:00', by: @ada) do
          sales = make_set('Sales rep')
          [@ana, @bo].each { |person| assign(person, sales) }
        end
        travel_to(Time.zone.local(2026, 6, 10, 10)) do
          as(@ada) { admin(:post, "/assignments/#{assignment_id(@ana, sales)}/keep", reason: 'Q2 access review') }
        end
        travel_to(Time.zone.local(2026, 6, 11, 11)) { as_basic { admin(:post, "/assignments/#{assignment_id(@bo, sales)}/keep") } }
        travel_to(Time.zone.local(2026, 7, 1)) { as(@ben) { admin(:patch, "/assignments/#{assignment_id(@ana, sales)}", expiry: 'eom') } }

        reviews = log_rows(event: 'assignment.reviewed')
        assert_equal(["#{BASIC_NAME} reviewed Bo Berisha's access to Sales rep.", "Ada Admin reviewed Ana Krasniqi's access to Sales rep."],
                     reviews.map { |row| row['sentence'] })
        assert_equal([Time.zone.local(2026, 6, 11, 11), Time.zone.local(2026, 6, 10, 10)], reviews.map { |row| row['at'] })
        assert_equal([nil, 'Reason: Q2 access review'], reviews.map { |row| row['reason'] })
        _, rows = csv_export(event: 'assignment.reviewed')
        assert_equal(%w[keep keep], rows.map { |row| row.dig('data', 'decision') })

        held = holdings.select { |row| row['permission_set'] == 'Sales rep' }.to_h { |row| [row['person'], row] }
        assert_equal ['Ada Admin', Time.zone.local(2026, 6, 10, 10)],
                     [held['Ana Krasniqi']['reviewed_by'], Time.iso8601(held['Ana Krasniqi']['reviewed_at'])],
                     'the later end-date change did not move the review'
        assert_equal Time.zone.local(2026, 6, 11, 11), Time.iso8601(held['Bo Berisha']['reviewed_at'])
      end

      # --- 10 --------------------------------------------------------------------------

      # 0.12.2: nothing recorded the settings in force, so a period with
      # auditing off left no trace, and a view_all read past the record rules
      # was not recorded (on_rule_bypass, when set, went to the host's own sink).
      test '10. was auditing ever off, and were the record rules ever bypassed' do
        reports = travel_to(Time.zone.local(2026, 1, 2)) { make_set('Reports') }
        travel_to(Time.zone.local(2026, 1, 5, 6)) { boot_with(audit_events: false) }
        travel_to(Time.zone.local(2026, 1, 6, 12)) do
          as(@ada) { admin(:patch, "/permission_sets/#{reports}/apply", pf: { set: { name: 'Reports (renamed)' } }) }
        end
        travel_to(Time.zone.local(2026, 1, 9, 6)) { boot_with(audit_events: :auto) }
        travel_to(Time.zone.local(2026, 2, 1)) { build_view_all_reader }
        customer = create_customer(name: 'Acme')
        with_runtime_events(%i[denied bypass]) do
          travel_to(Time.zone.local(2026, 2, 2, 9)) { as_host_user(@bo) { Customer.find_by(id: customer.id) } }
          travel_to(Time.zone.local(2026, 2, 2, 3)) { as_host_user(nil) { Customer.find_by(id: customer.id) } } # a job with no user
        end

        observed = json_export(event: 'audit.settings_observed')['data']
        switches = observed.map { |row| [Time.iso8601(row['occurred_at']), row.dig('data', 'settings', 'audit_events')] }
        assert_equal [[Time.zone.local(2026, 1, 5, 6), false], [Time.zone.local(2026, 1, 9, 6), 'auto']], switches
        assert_equal(['The audit settings in force were recorded.'] * 2, log_rows(event: 'audit.settings_observed').map { |row| row['sentence'] })
        # The set is called "Reports (renamed)" today, but the log only knows it
        # was created as "Reports": the rename happened while recording was off.
        renamed = permission_set_filter_value('Reports (renamed)')
        assert_equal([['permission_set.created', 'Reports']],
                     log_rows(permission_set: renamed, category: 'change').map { |row| [row['event'], row['sentence'][/Reports[^.]*/]] })
        _, gap = csv_export(category: 'change', from: '2026-01-05', to: '2026-01-08')
        assert_empty gap, 'nothing at all is recorded between the two boots'

        bypassed = api_events(event: 'rule.bypassed').map do |row|
          [row['actor_type'], row['actor_label'], row.dig('data', 'reason'), row.dig('data', 'model')]
        end
        assert_equal [['user', 'Bo Berisha', 'view_all', 'Customer'], ['unknown', nil, 'nil_user', 'Customer']], bypassed
        assert_includes log_rows(event: 'rule.bypassed').map { |row| row['sentence'] }, 'Record rules on Customer were skipped for Bo Berisha.'
      end

      # --- 11 --------------------------------------------------------------------------

      # 0.12.2: Ben's created_by/updated_by ids pointed at a deleted user on the
      # rows nobody edited since, and nowhere else; his grant and his field
      # change were overwritten or deleted. Nothing listed what he had changed.
      test '11. everything an admin who has left changed' do
        dee = create_user(name: 'Dee Departed', email: 'dee@acme.test')
        travel_to(Time.zone.local(2026, 2, 10)) do
          as(@ben) do
            field_ops = make_set('Field ops', by: @ben)
            add_resource(field_ops)
            mask_email(field_ops)
            assign(@bo, field_ops)
          end
        end
        field_ops = PermissionForge::PermissionSet.find_by!(name: 'Field ops').id
        on('2026-02-11 09:00', by: @ada) { assign(@ben, field_ops) }
        on('2026-02-20 09:00', by: dee) { assign(@ana, field_ops) }
        travel_to(Time.zone.local(2026, 3, 1)) { as(@ada) { admin(:post, "/people/#{@ben.id}/erasure", confirmation: 'Ben Builder') } }
        [@ben, dee].each(&:destroy!) # the host deletes both user rows

        get pf('/audit.csv')
        assert_response :success
        refute_includes response.body, 'Ben Builder', 'his name is gone from every event, whoever wrote it'
        _, erasures = csv_export(event: 'erasure.performed')
        ben = erasures.sole['subject_user_id']
        _, by_ben = csv_export(actor_type: 'user', actor_id: ben)
        assert_equal([['permission_set.created', 'Field ops'], ['resource.created', 'Customer'],
                      ['resource_field.updated', 'Customer.email'], ['assignment.granted', 'Bo Berisha']],
                     by_ben.reject { |row| row['event'] == 'resource_field.created' }.map { |row| row.values_at('event', 'record_label') })
        assert(by_ben.all? { |row| row['actor_label'].blank? }, 'erasure removed his name from his events; his id stays')
        assert_equal ["Person ##{ben}"], log_rows(actor_type: 'user', actor_id: ben).map { |row| row['actor'] }.uniq

        granted = log_rows(event: 'assignment.granted', permission_set: permission_set_filter_value('Field ops'))
        dee_row = granted.find { |row| row['actor'] == 'Dee Departed' }
        dee_id = Rack::Utils.parse_query(URI(dee_row['actor_href']).query)['actor_id']
        _, by_dee = csv_export(actor_type: 'user', actor_id: dee_id)
        assert_equal [['assignment.granted', 'Dee Departed', 'Ana Krasniqi']],
                     by_dee.map { |row| row.values_at('event', 'actor_label', 'record_label') }, 'a deleted (not erased) admin keeps her name'
      end

      # --- 12 --------------------------------------------------------------------------

      # 0.12.2: the nightly clean-up hard-deleted the expired row, so nothing
      # showed that Bo had ever held Contractors Q1, until when, or who gave it.
      test '12. did an assignment that expired and was cleaned up ever exist' do
        on('2026-01-10 09:00', by: @ada) do
          assign(@bo, make_set('Contractors Q1'), expiry: 'custom', custom_date: '2026-01-31', reason: 'TCK-12')
        end
        travel_to(Time.zone.local(2026, 2, 15, 2)) { nightly_cleanup(actor: 'nightly-cleanup') }

        assert_empty holdings.select { |row| row['permission_set'] == 'Contractors Q1' }, 'today nobody holds it'
        bo = person_id('Bo Berisha')
        history = api_events(subject_user_id: bo, permission_set: permission_set_filter_value('Contractors Q1'))
        assert_equal([['assignment.revoked', 'system', 'nightly-cleanup', 'rake'], ['assignment.granted', 'user', 'Ada Admin', 'admin_ui']],
                     history.map { |row| row.values_at('event', 'actor_type', 'actor_label', 'source') })
        revoked, granted = history
        assert_equal([Date.new(2026, 1, 31)] * 2, [granted, revoked].map { |row| local_date(row.dig('data', 'snapshot', 'expires_at')) })
        assert_equal 'TCK-12', granted['reason']
        assert_equal Time.zone.local(2026, 2, 15, 2), Time.iso8601(revoked['occurred_at'])

        cleanup = api_events(event: 'cleanup.expired_assignments').sole
        assert_includes cleanup.dig('data', 'affected_user_ids').map(&:to_s), bo
        assert_equal revoked['correlation_id'], cleanup['correlation_id'], 'the revocation belongs to that clean-up run'
      end

      private

      # --- acting -------------------------------------------------------------------------

      # The admin screens, signed in as `user` (current_user_resolver).
      def as(user)
        previous = PermissionForge.configuration.current_user_resolver
        sign_in(user)
        yield
      ensure
        PermissionForge.configuration.current_user_resolver = previous
      end

      # The admin screens through the shared HTTP Basic login, nobody signed in.
      def as_basic
        sign_in(nil)
        enable_basic_auth(user: BASIC_USER, password: BASIC_PASSWORD)
        @headers = basic_auth_header(BASIC_USER, BASIC_PASSWORD)
        yield
      ensure
        PermissionForge.configuration.http_basic_auth_enabled = false
        @headers = {}
        sign_in(@ivy)
      end

      # The host application's own code running for `user` (nil: a job).
      def as_host_user(user, &)
        as(user, &)
      end

      def admin(verb, path, **params)
        public_send(verb, pf(path), params: params, headers: @headers)
        assert_operator response.status, :<, 400, "#{verb.upcase} #{path} answered #{response.status}"
      end

      def make_set(name, by: @ada)
        as(by) { admin(:post, '/permission_sets', type: 'granting', name: name) }
        PermissionForge::PermissionSet.find_by!(name: name).id
      end

      def field_path(set, field)
        "/permission_sets/#{set}/resources/Customer/fields/#{field}"
      end

      # The row the admin clicks on: ids for the URLs only, never an answer.
      def assignment_id(user, set)
        PermissionForge::PermissionSetUser.find_by!(user: user, permission_set_id: set).id
      end

      def resource_id(set)
        PermissionForge::Resource.find_by!(permission_set_id: set, name: 'Customer').id
      end

      def field_id(set, name)
        PermissionForge::ResourceField.find_by!(resource_id: resource_id(set), name: name).id
      end

      # The engine records the audit settings at boot.
      def boot_with(audit_events:)
        PermissionForge.configuration.audit_events = audit_events
        PermissionForge::Audit.reset!
        PermissionForge::Audit::SettingsObserver.call
      end

      def with_runtime_events(groups)
        previous = PermissionForge.configuration.audit_runtime_events
        PermissionForge.configuration.audit_runtime_events = groups
        yield
      ensure
        PermissionForge.configuration.audit_runtime_events = previous
      end

      # The app's time zone (config.time_zone) for the block. use_zone first:
      # it restores the zone it found, which must not be the one set here.
      def with_zone(name)
        previous = Time.zone_default
        Time.use_zone(name) do
          Time.zone_default = ActiveSupport::TimeZone[name]
          yield
        ensure
          Time.zone_default = previous
        end
      end

      # `rake permission_forge:cleanup_expired_assignments ACTOR=…`, as cron runs it.
      def nightly_cleanup(actor:)
        previous_app = Rake.application
        previous_actor = ENV.fetch('ACTOR', nil)
        Rake.application = self.class.rake_application
        Rake::Task['permission_forge:cleanup_expired_assignments'].reenable
        ENV['ACTOR'] = actor
        capture_io { Rake::Task['permission_forge:cleanup_expired_assignments'].invoke }
      ensure
        Rake.application = previous_app
        ENV['ACTOR'] = previous_actor
      end

      # --- stories ------------------------------------------------------------------------

      # Support: Customer readable from 1 March, email masked on 15 March,
      # Edit on (and name editable) on 10 April, a rule from 20 May, then on
      # 5 June email unmasked, the rule deleted and Edit off again.
      def build_support_history
        on('2026-03-01 10:00', by: @ada) { add_resource(@support = make_set('Support')) }
        on('2026-03-15 10:00', by: @ada) { mask_email(@support) }
        on('2026-04-10 10:00', by: @ben) { turn_edit_on(@support) }
        on('2026-05-20 10:00', by: @ben) { add_rule(@support, 'Acme only', 'domain', 'acme.test') }
        on('2026-06-05 10:00', by: @ada) { undo_support_changes }
      end

      # In the admin screens at a local time, as `by`.
      def on(local_time, by:, &)
        travel_to(Time.zone.parse(local_time)) { as(by, &) }
      end

      def mask_email(set)
        admin(:patch, field_path(set, 'email'), field: { level: 'masked', mask_strategy: 'email' })
      end

      def turn_edit_on(set)
        edit = { resources: { resource_id(set) => { edit_access: '1' } }, fields: { field_id(set, 'name') => { level: 'edit' } } }
        admin(:patch, "/permission_sets/#{set}/apply", pf: edit)
      end

      def add_rule(set, name, field, value)
        admin(:post, "/permission_sets/#{set}/resources/Customer/rules",
              rule: { name: name, field_name: field, operator: 'equal', value: value })
      end

      def add_resource(set)
        admin(:post, "/permission_sets/#{set}/resources", model_name: 'Customer', preset: 'read')
      end

      def assign(user, set, expiry: 'never', **more)
        admin(:post, '/assignments', user_id: user.id, set_ids: [set], expiry: expiry, **more)
      end

      def undo_support_changes
        rule = PermissionForge::PermissionSetRule.find_by!(name: 'Acme only').id
        as(@ada) do
          admin(:patch, field_path(@support, 'email'), field: { level: 'read' })
          admin(:delete, "/permission_sets/#{@support}/resources/Customer/rules/#{rule}")
          admin(:patch, "/permission_sets/#{@support}/apply", pf: { resources: { resource_id(@support) => { edit_access: '0' } } })
        end
      end

      # Support desk (email masked) held by Bo; Billing (email readable) held by
      # Ana, and by Cat until it ended.
      def build_email_access
        cat = create_user(name: 'Cat Contractor', email: 'cat@acme.test')
        desk = make_set('Support desk')
        billing = make_set('Billing')
        as(@ada) do
          [desk, billing].each { |set| add_resource(set) }
          mask_email(desk)
          assign(@bo, desk)
          assign(@ana, billing)
        end
        travel_to(2.months.ago) { as(@ada) { assign(cat, billing, expiry: '1w') } }
      end

      # Contractors: Customer readable with email masked, two rules, held by Bo.
      def build_contractors(contractors)
        as(@ada) do
          add_resource(contractors)
          mask_email(contractors)
          add_rule(contractors, 'Acme only', 'domain', 'acme.test')
          add_rule(contractors, 'Named', 'name', 'Acme')
          assign(@bo, contractors)
        end
      end

      # Auditors: Customer with View All, held by Bo.
      def build_view_all_reader
        auditors = make_set('Auditors')
        as(@ada) do
          add_resource(auditors)
          admin(:patch, "/permission_sets/#{auditors}/apply", pf: { resources: { resource_id(auditors) => { view_all: '1' } } })
          assign(@bo, auditors)
        end
      end

      # --- what an investigator reads -----------------------------------------------------

      # The Audit log page: one Hash per row, newest first.
      def log_rows(**filters)
        get pf('/audit'), params: filters
        assert_response :success
        css_select('li.pf-audit-event').map { |row| log_row(row) }
      end

      def log_row(row)
        sentence = row.at_css('a.pf-audit-event__sentence')
        event, actor = row.css('.pf-audit-event__meta a').first(2)
        { 'uuid' => sentence['href'].split('/').last, 'sentence' => sentence.text.strip, 'event' => event.text.strip,
          'actor' => actor.text.strip, 'actor_href' => actor['href'] }.merge(log_row_when_and_why(row))
      end

      def log_row_when_and_why(row)
        { 'at' => Time.iso8601(row.at_css('time')['datetime']), 'reason' => row.at_css('.pf-audit-event__reason')&.text&.strip }
      end

      # One event's page: the sentence, the who/what facts by label, the
      # before/after table, the snapshot table.
      def event_page(uuid)
        get pf("/audit/#{uuid}")
        assert_response :success
        css_select('.pf-sr-only, [aria-hidden=true]').each(&:remove) # read as a sighted reader does
        { 'sentence' => css_select('h1').first.text.strip, 'facts' => facts,
          'changes' => table_rows('pf-event-changes').transform_values { |cells| cells.first(2) },
          'snapshot' => table_rows('pf-event-snapshot').transform_values(&:first) }
      end

      # The who/where/why and what cards, by label.
      def facts
        css_select('dl.pf-kv dt').to_h { |term| [term.text.strip, term.next_element.text.squish] }
      end

      def table_rows(section)
        css_select("section[aria-labelledby=#{section}] tbody tr").to_h do |row|
          [row.at_css('th').text.strip, row.css('td').map { |cell| cell.text.strip }]
        end
      end

      # The CSV export of the filtered log: [metadata, rows as Hashes, data parsed].
      def csv_export(path = '/audit.csv', **filters)
        get pf(path), params: filters
        assert_response :success
        meta, columns, rows = PermissionForge::Admin::CsvReading.export(response.body)
        [meta, rows.map { |row| columns.zip(row).to_h.tap { |h| h['data'] = JSON.parse(h['data']) if h['data'].present? } }]
      end

      def json_export(**filters)
        get pf('/audit.json'), params: filters
        assert_response :success
        JSON.parse(response.body)
      end

      # "Who holds what" today.
      def holdings
        csv_export('/audit/holdings.csv').last
      end

      # GET /api/audit_events, every page, newest first.
      def api_events(**filters)
        rows = []
        (1..).each do |page|
          get pf('/api/audit_events'), params: filters.compact.merge(per_page: 100, page: page)
          assert_response :success
          body = JSON.parse(response.body)
          rows.concat(body['data'])
          break if body['data'].empty? || rows.size >= body.dig('meta', 'pagination', 'total_count')
        end
        rows
      end

      # The People page: the id behind a name.
      def person_id(name)
        get pf('/people'), params: { q: name }
        assert_response :success
        link = css_select('.pf-table__row--link').find { |row| row.text.include?(name) }&.at_css('a.pf-cell-person')
        assert link, "#{name} is on the People page"
        link['href'].split('/').last
      end

      # The Audit log's Permission Set filter: the id behind a name.
      def permission_set_filter_value(name)
        get pf('/audit')
        option = css_select('select[name=permission_set] option').find { |opt| opt.text.strip == name }
        assert option, "#{name} is in the Permission Set filter"
        option['value']
      end

      def local_date(value)
        Time.iso8601(value).in_time_zone.to_date
      end

      def allowed_at(rows, as_of:)
        Allowed.call(EventReplay.new(rows).as_of(as_of))
      end

      def pf(path)
        "#{ROOT}#{path}"
      end
    end
  end
end
