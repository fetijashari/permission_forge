# frozen_string_literal: true

require 'test_helper'
require_relative '../tenancy/tenancy_test_helper'

module PermissionForge
  module Api
    class AuditEventsControllerTest < ActionDispatch::IntegrationTest
      include PermissionForge::Tenancy::TenancyTestHelper

      BASE = '/permission_forge/api/audit_events'

      setup do
        @config = PermissionForge.configuration
        @saved = %i[api_auth api_enabled audit_log_authorization api_record_identifier api_max_per_page
                    api_serializer_overrides].to_h { |name| [name, @config.public_send(name)] }
        @t0 = Time.utc(2026, 3, 1, 12)
        @ids = []
      end

      teardown do
        @saved.each { |name, value| @config.public_send(:"#{name}=", value) }
      end

      def make(event = 'report.generated', **attrs)
        record = PermissionForge::Audit.record(event, occurred_at: @t0, **attrs)
        @ids << record.id
        record
      end

      def body = JSON.parse(response.body)
      # Reading the log is itself recorded (audit.viewed, scope 'api'): the
      # reads of earlier requests in a test are left out of what it compares.
      def rows = body['data'].reject { |row| own_read?(row) }
      def own_read?(row) = row['event'] == 'audit.viewed' && row.dig('data', 'scope') == 'api'
      def uuids = rows.map { |row| row['uuid'] }
      def errors = body.dig('error', 'messages')

      # --- listing and serialization ---

      test 'index lists newest first inside the standard envelope' do
        older = make(occurred_at: @t0)
        newer = make(occurred_at: @t0 + 1.hour)
        same_instant = make(occurred_at: @t0 + 1.hour)

        get BASE, params: { event: 'report.generated' }

        assert_response :ok
        assert_equal [same_instant.uuid, newer.uuid, older.uuid], uuids
        assert_equal({ 'page' => 1, 'per_page' => 15, 'total_count' => 3 }, body.dig('meta', 'pagination'))
      end

      test 'a row carries every column but the tenant column, data as an object and ISO 8601 times' do
        set = create_permission_set
        event = make('permission_set.cloned', record: set, reason: 'TCK-1', data: { 'source_uuid' => 'abc' })

        get "#{BASE}/#{event.uuid}"

        assert_response :ok
        row = body['data']
        columns = PermissionForge::AuditEvent.column_names - [PermissionForge.configuration.resolved_tenant_column.to_s]
        assert_equal columns.sort, row.keys.sort
        assert_equal({ 'source_uuid' => 'abc' }, row['data'])
        assert_equal 'TCK-1', row['reason']
        assert_equal @t0.iso8601(6), row['occurred_at']
        assert_match(/\A\d{4}-\d\d-\d\dT[\d:.]+Z\z/, row['created_at'])
        assert_equal set.uuid, row['record_uuid']
      end

      test 'an event with no data serializes an empty object' do
        event = make

        get "#{BASE}/#{event.uuid}"

        assert_equal({}, body.dig('data', 'data'))
      end

      test 'show finds by uuid or by id per api_record_identifier' do
        event = make

        get "#{BASE}/#{event.uuid}"
        assert_response :ok

        get "#{BASE}/#{event.id}"
        assert_response :not_found

        @config.api_record_identifier = :id
        get "#{BASE}/#{event.id}"
        assert_response :ok
        assert_equal event.uuid, body.dig('data', 'uuid')

        get "#{BASE}/#{event.uuid}"
        assert_response :not_found
      end

      test 'show of an unknown identifier is a 404 envelope' do
        get "#{BASE}/nope"

        assert_response :not_found
        assert_equal 404, body.dig('error', 'status')
      end

      test 'api_serializer_overrides applies to the audit_event serializer' do
        custom = Class.new(PermissionForge::Api::Serializers::BaseSerializer) { attributes :uuid }
        @config.api_serializer_overrides = { audit_event: custom }
        event = make

        get "#{BASE}/#{event.uuid}"

        assert_equal({ 'uuid' => event.uuid }, body['data'])
      end

      # --- filters ---

      test 'from and to bound occurred_at, inclusive, with timestamps and plain dates' do
        early = make(occurred_at: Time.utc(2026, 1, 1, 8))
        mid = make(occurred_at: Time.utc(2026, 2, 1, 8))
        late = make(occurred_at: Time.utc(2026, 3, 1, 8))

        get BASE, params: { from: '2026-02-01T08:00:00Z', to: '2026-02-01T08:00:00Z', event: 'report.generated' }
        assert_equal [mid.uuid], uuids

        get BASE, params: { from: '2026-02-01', event: 'report.generated' }
        assert_equal [late.uuid, mid.uuid], uuids

        get BASE, params: { to: '2026-02-01', event: 'report.generated' }
        assert_equal [mid.uuid, early.uuid], uuids
      end

      test 'a time with an offset is honoured' do
        event = make(occurred_at: Time.utc(2026, 2, 1, 8))

        get BASE, params: { from: '2026-02-01T10:00:00+02:00', to: '2026-02-01T10:00:00+02:00' }

        assert_includes uuids, event.uuid
      end

      test 'an invalid from or to is a 422 naming the parameter' do
        ['yesterday', '2026-13-45', '1; DROP TABLE x', '2026-02-01 08:00 pm'].each do |bad|
          get BASE, params: { from: bad, to: bad }

          assert_response :unprocessable_entity, bad
          assert_equal 422, body.dig('error', 'status')
          assert_equal %w[from to], errors.keys.sort
        end
      end

      test 'an offset-less timestamp is read in UTC whatever the process time zone' do
        event = make(occurred_at: Time.utc(2026, 2, 1, 8))
        previous = ENV.fetch('TZ', nil)
        begin
          ['Asia/Tokyo', 'America/Los_Angeles', 'UTC'].each do |zone|
            ENV['TZ'] = zone
            get BASE, params: { from: '2026-02-01T08:00:00', to: '2026-02-01T08:00:00.5' }
            assert_equal [event.uuid], uuids, zone

            get BASE, params: { from: '2026-02-01T08:00:01' }
            assert_empty rows, zone
          end
        ensure
          ENV['TZ'] = previous
        end
      end

      test 'impossible dates, times and years are a 422, never rolled over' do
        ['2026-02-30T00:00:00Z', '2026-02-30', '2026-04-31', '2026-01-01T24:00:00Z', '2026-01-01T10:61:00Z',
         '2026-01-01T10:00:00+25:00', '0000-01-01', '10000-01-01', '12345-01-01T00:00:00Z', '0000-01-01T00:00:00Z',
         '-001-01-01'].each do |bad|
          get BASE, params: { from: bad }
          assert_response :unprocessable_entity, bad
          assert_equal ['from'], errors.keys, bad
        end
      end

      test 'a NUL byte in a filter value is a 422' do
        %i[actor_id subject_user_id correlation_id record_type permission_set category actor_type event from].each do |name|
          get BASE, params: { name => "a\0b" }
          assert_response :unprocessable_entity, name.to_s
        end
        get BASE, params: { event: ["report.generated\0"] }
        assert_response :unprocessable_entity
      end

      test 'event takes an exact name, a list or a comma list, registered names only' do
        a = make('report.generated')
        b = make('consent.withdrawn')
        make('cleanup.expired_assignments')

        get BASE, params: { event: 'report.generated' }
        assert_equal [a.uuid], uuids

        get BASE, params: { event: %w[report.generated consent.withdrawn] }
        assert_equal [a.uuid, b.uuid].sort, uuids.sort

        get BASE, params: { event: 'report.generated,consent.withdrawn' }
        assert_equal [a.uuid, b.uuid].sort, uuids.sort

        get BASE, params: { event: 'report.nonexistent' }
        assert_response :unprocessable_entity
        assert_equal ['event'], errors.keys

        get BASE, params: { event: %w[report.generated nope] }
        assert_response :unprocessable_entity

        get BASE, params: { event: { 'a' => 'b' } }
        assert_response :unprocessable_entity
      end

      test 'reading the log is recorded as audit.viewed, with the actor and the filters' do
        get BASE, params: { event: 'report.generated' }

        assert_response :ok
        assert_audit_event('audit.viewed', source: 'api', actor_type: 'api',
                                           data: { 'scope' => 'api', 'filters' => { 'event' => 'report.generated' } })
      end

      test 'category and actor_type accept only known values' do
        make('report.generated')
        admin_event = make('audit.viewed', actor: { type: 'api', id: '9', label: 'Token' })

        get BASE, params: { category: 'admin' }
        assert_equal [admin_event.uuid], uuids

        get BASE, params: { actor_type: 'api' }
        assert_equal [admin_event.uuid], uuids

        get BASE, params: { category: 'bogus' }
        assert_response :unprocessable_entity

        get BASE, params: { actor_type: 'robot' }
        assert_response :unprocessable_entity
      end

      test 'actor_id, subject_user_id and correlation_id filter by equality' do
        target = make('audit.viewed', actor: { type: 'api', id: '77', label: 'T' }, subject_user_id: 5)
        make('audit.viewed', actor: { type: 'api', id: '78', label: 'T' }, subject_user_id: 6)
        target_correlation = PermissionForge::AuditEvent.where(id: target.id).pick(:correlation_id)

        get BASE, params: { actor_id: '77' }
        assert_equal [target.uuid], uuids

        get BASE, params: { subject_user_id: '5' }
        assert_equal [target.uuid], uuids

        get BASE, params: { actor_id: '77', subject_user_id: '6' }
        assert_empty rows

        if target_correlation
          get BASE, params: { correlation_id: target_correlation }
          assert_includes uuids, target.uuid
        end
      end

      test 'permission_set filters by uuid or id' do
        set = create_permission_set(name: 'One')
        other = create_permission_set(name: 'Two')
        mine = make('permission_set.cloned', record: set)
        make('permission_set.cloned', record: other)

        get BASE, params: { permission_set: set.uuid, event: 'permission_set.cloned' }
        assert_equal [mine.uuid], uuids

        get BASE, params: { permission_set: set.id.to_s, event: 'permission_set.cloned' }
        assert_equal [mine.uuid], uuids

        get BASE, params: { permission_set: '0', event: 'permission_set.cloned' }
        assert_empty rows
      end

      test 'a numeric permission_set filters the id only, a uuid the uuid only' do
        set = create_permission_set
        by_id = make('permission_set.cloned', permission_set_id: set.id)
        by_uuid = make('permission_set.cloned', permission_set_uuid: set.id.to_s)

        get BASE, params: { permission_set: set.id.to_s, event: 'permission_set.cloned' }
        assert_equal [by_id.uuid], uuids

        get BASE, params: { permission_set: "x#{set.id}", event: 'permission_set.cloned' }
        assert_empty rows
        assert by_uuid
      end

      test 'record_id and record_uuid each match their own column and need record_type' do
        set = create_permission_set
        event = make('permission_set.cloned', record: set)

        get BASE, params: { record_type: 'PermissionForge::PermissionSet', record_id: set.id.to_s, event: 'permission_set.cloned' }
        assert_equal [event.uuid], uuids

        get BASE, params: { record_type: 'PermissionForge::PermissionSet', record_uuid: set.uuid, event: 'permission_set.cloned' }
        assert_equal [event.uuid], uuids

        get BASE, params: { record_type: 'PermissionForge::Resource', event: 'permission_set.cloned' }
        assert_empty rows

        get BASE, params: { record_type: 'PermissionForge::PermissionSet', record_id: set.uuid, event: 'permission_set.cloned' }
        assert_empty rows

        get BASE, params: { record_type: 'PermissionForge::PermissionSet', record_uuid: set.id.to_s, event: 'permission_set.cloned' }
        assert_empty rows

        [{ record_id: '1' }, { record_uuid: 'x' }].each do |bad|
          get BASE, params: bad
          assert_response :unprocessable_entity
          assert_equal ['record_type'], errors.keys
        end

        get BASE, params: { record_type: 'T', record_uuid: "a\0b" }
        assert_response :unprocessable_entity
      end

      test 'filter values are bound, never interpolated' do
        event = make('audit.viewed', actor: { type: 'api', id: '1', label: 'T' })
        payloads = ["1' OR '1'='1", '1) OR (1=1', "1'; DROP TABLE #{PermissionForge::AuditEvent.table_name};--", '%', '_']

        payloads.each do |payload|
          %i[actor_id subject_user_id correlation_id record_type permission_set].each do |name|
            params = { name => payload }
            params[:record_id] = payload if name == :record_type
            params[:record_uuid] = payload if name == :record_type
            get BASE, params: params

            assert_response :ok, "#{name}=#{payload}"
            assert_empty rows, "#{name}=#{payload}"
          end
        end

        get BASE, params: { actor_id: ['1', "' OR 1=1"] }
        assert_response :unprocessable_entity

        get BASE, params: { actor_id: { 'a' => '1' } }
        assert_response :unprocessable_entity

        get "#{BASE}/#{CGI.escape("' OR 1=1 --")}"
        assert_response :not_found

        assert PermissionForge::AuditEvent.exists?(event.id)
      end

      test 'unknown parameters are ignored' do
        event = make

        get BASE, params: { sort: 'occurred_at asc; drop', unknown: 'x', event: 'report.generated' }

        assert_response :ok
        assert_includes uuids, event.uuid
      end

      # --- pagination ---

      test 'pagination pages and reports the total' do
        made = Array.new(5) { |i| make(occurred_at: @t0 + i.minutes) }

        get BASE, params: { event: 'report.generated', per_page: 2, page: 2 }

        assert_equal [made[2].uuid, made[1].uuid], uuids
        assert_equal({ 'page' => 2, 'per_page' => 2, 'total_count' => 5 }, body.dig('meta', 'pagination'))
      end

      test 'per_page is capped at api_max_per_page and never below one' do
        Array.new(3) { make }
        @config.api_max_per_page = 2

        get BASE, params: { per_page: 1_000_000 }
        assert_equal 2, body.dig('meta', 'pagination', 'per_page')
        assert_operator rows.size, :<=, 2

        get BASE, params: { per_page: -5 }
        assert_equal 1, body.dig('meta', 'pagination', 'per_page')

        get BASE, params: { per_page: 'all' }
        assert_equal 1, body.dig('meta', 'pagination', 'per_page')
      end

      test 'the default cap is 100 rows' do
        assert_equal 100, PermissionForge::Configuration.new.api_max_per_page
      end

      test 'an absurd page number is an empty page, not a server error' do
        make

        get BASE, params: { page: '99999999999999999999999', event: 'report.generated' }

        assert_response :ok
        assert_empty rows
      end

      # --- verbs ---

      test 'an absurd page number is an empty page on every endpoint' do
        create_permission_set
        [(2**60).to_s, '99999999999999999999999'].each do |page|
          get '/permission_forge/api/permission_sets', params: { page: page }
          assert_response :ok
          assert_empty rows
        end
      end

      test 'no mutating verb is routed' do
        event = make
        [[:post, BASE], [:patch, "#{BASE}/#{event.uuid}"], [:put, "#{BASE}/#{event.uuid}"],
         [:delete, "#{BASE}/#{event.uuid}"], [:delete, BASE]].each do |verb, path|
          status = begin
            public_send(verb, path)
            response.status
          rescue ActionController::RoutingError
            404
          end

          assert_equal 404, status, "#{verb} #{path}"
        end
        assert PermissionForge::AuditEvent.exists?(event.id)
      end

      test 'the engine draws only index and show for audit events' do
        verbs = PermissionForge::Engine.routes.routes.select { |route| route.path.spec.to_s.include?('audit_events') }
                                       .map(&:verb).uniq
        assert_equal ['GET'], verbs
      end

      # --- authentication and authorization ---

      test 'api disabled is a 404' do
        @config.api_enabled = false

        get BASE

        assert_response :not_found
      end

      test 'no api_auth is a 401 and a refusing api_auth a 403' do
        @config.api_auth = nil
        get BASE
        assert_response :unauthorized

        @config.api_auth = ->(_controller) { false }
        get BASE
        assert_response :forbidden
        get "#{BASE}/x"
        assert_response :forbidden
      end

      test 'audit_log_authorization nil lets an authenticated client read' do
        @config.audit_log_authorization = nil

        get BASE

        assert_response :ok
      end

      test 'audit_log_authorization allows only an exact true' do
        event = make
        @config.audit_log_authorization = ->(controller) { controller.is_a?(PermissionForge::Api::AuditEventsController) }
        get BASE
        assert_response :ok
        get "#{BASE}/#{event.uuid}"
        assert_response :ok

        [false, nil, 'yes', 1, 'true'].each do |answer|
          @config.audit_log_authorization = ->(_controller) { answer }
          get BASE
          assert_response :forbidden, answer.inspect
          get "#{BASE}/#{event.uuid}"
          assert_response :forbidden, answer.inspect
        end
      end

      test 'audit_log_authorization answering with an object whose == is true still denies' do
        liar = Object.new
        liar.define_singleton_method(:==) { |_other| true }
        @config.audit_log_authorization = ->(_controller) { liar }

        get BASE

        assert_response :forbidden
      end

      test 'a raising audit_log_authorization denies' do
        @config.audit_log_authorization = ->(_controller) { raise 'boom' }
        errors_seen = []
        subscriber = Rails.error.respond_to?(:subscribe) ? Object.new : nil
        subscriber&.define_singleton_method(:report) { |error, **| errors_seen << error }
        Rails.error.subscribe(subscriber) if subscriber

        get BASE

        assert_response :forbidden
        assert_equal 403, body.dig('error', 'status')
      ensure
        Rails.error.unsubscribe(subscriber) if subscriber
      end

      test 'authorization does not run for an unauthenticated request' do
        called = false
        @config.api_auth = ->(_controller) { false }
        @config.audit_log_authorization = ->(_controller) { called = true }

        get BASE

        assert_response :forbidden
        refute called
      end

      # --- tenant isolation ---

      test 'events of another tenant are neither listed nor shown' do
        tenant_a = Account.create!(name: 'A')
        tenant_b = Account.create!(name: 'B')
        within(tenant_a) { @mine = make('audit.viewed', actor: { type: 'api', id: '1', label: 'A' }) }
        within(tenant_b) { @theirs = make('audit.viewed', actor: { type: 'api', id: '2', label: 'B' }) }

        within(tenant_a) do
          get BASE, params: { event: 'audit.viewed' }
          assert_equal [@mine.uuid], uuids
          assert_equal 1, body.dig('meta', 'pagination', 'total_count')

          get BASE, params: { actor_id: '2' }
          assert_empty rows

          get "#{BASE}/#{@theirs.uuid}"
          assert_response :not_found

          @config.api_record_identifier = :id
          get "#{BASE}/#{@theirs.id}"
          assert_response :not_found
        end

        within(tenant_b) do
          get BASE, params: { event: 'audit.viewed' }
          assert_equal [@theirs.uuid], uuids
        end
      end
    end
  end
end
