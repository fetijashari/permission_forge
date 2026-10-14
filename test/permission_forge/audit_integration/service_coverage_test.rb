# frozen_string_literal: true

require_relative 'integration_support'

module PermissionForge
  module AuditIntegration
    # Every service, admin writer, model entry point and rake task that
    # changes data writes its audit events with who ran it, why, from where,
    # and one correlation id for the whole call.
    #
    # Coverage heuristic (what makes a new writer without an entry fail):
    # - every file under lib/permission_forge/services/ (files in a sub
    #   directory other than concerns/ count as their parent service) must be
    #   in SERVICES, either with the events it writes or with the reason it
    #   writes nothing;
    # - a services/ or admin/ file whose code calls an ActiveRecord write
    #   (create, save, update, destroy, find_or_create_by, the bulk writes …)
    #   or a writer listed here (`PermissionSetCloner.call` …) must be listed
    #   as a writer, never as writing nothing;
    # - every rake task in lib/tasks/ must be in RAKE_TASKS.
    # Model entry points (grant_full_access!, deep_clone, mark_reviewed!) are
    # listed by hand: a model's public writers are not found by the scan.
    class ServiceCoverageTest < ActiveSupport::TestCase
      include IntegrationSupport

      SERVICES_DIR = PermissionForge::Engine.root.join('lib/permission_forge/services')
      ADMIN_DIR = PermissionForge::Engine.root.join('lib/permission_forge/admin')

      CLONE_EVENTS = %w[permission_set.cloned permission_set.created permission_set_rule.created resource.created
                        resource_action.created resource_field.created].freeze
      GROUP_CLONE_EVENTS = (CLONE_EVENTS + %w[permission_set_group.cloned permission_set_group.created]).sort.freeze

      # file under services/ (without .rb) => { events:, drive: } | { none: }
      SERVICES = {
        'attribute_access_guard' => { none: 'decides one attribute read (field.access is a runtime event)' },
        'audit_event_purger' => { events: %w[audit.purged], drive: :purger },
        'bulk_permission_set_assignment' => { events: %w[assignment.granted], drive: :bulk_assignment },
        'concerns/across_tenants' => { none: 'runs a tenant-less service across tenants; its summaries are its service’s events' },
        'concerns/audited_operation' => { none: 'the audit context of the housekeeping services; writes nothing itself' },
        'concerns/clonable' => { events: CLONE_EVENTS, drive: :set_cloner },
        'consent_withdrawal_handler' => { events: %w[assignment.revoked consent.withdrawn], drive: :consent },
        'dashboard_stats' => { none: 'counts for the dashboard' },
        'data_subject_erasure' => { events: %w[assignment.revoked erasure.performed group_membership.removed], drive: :erasure },
        'expired_assignment_cleaner' => { events: %w[assignment.revoked cleanup.expired_assignments], drive: :cleaner },
        'extra_field_defaults' => { none: 'adds implicit field grants to an in-memory permission hash' },
        'field_permission_merger' => { none: 'merges field rows into an in-memory permission hash' },
        'filters_response_attributes' => { none: 'filters a response hash (field.access is a runtime event)' },
        'gdpr_field_auditor' => { none: 'read-only report (the rake task records report.generated)' },
        'host_key_guard' => { none: 'reads the schema and refuses a column that would truncate a host key' },
        'mask_value' => { none: 'masks a value' },
        'permission_cache_clearer' => { events: %w[cache.cleared], drive: :cache_clearer },
        'permission_hash_builder' => { none: 'builds the permission hash in memory' },
        'permission_rule_applier' => { none: 'builds a query (access.denied / rule.bypassed are runtime events)' },
        'permission_set_cloner' => { events: CLONE_EVENTS, drive: :set_cloner },
        'permission_set_condition_evaluator' => { none: 'evaluates activation conditions' },
        'permission_set_group_cloner' => { events: GROUP_CLONE_EVENTS, drive: :group_cloner },
        'permits_attributes' => { none: 'filters params (params.filtered is a runtime event)' },
        'resource_field_generator' => { events: %w[resource_field.created], drive: :field_generator },
        'resource_with_fields_builder' => { events: %w[resource.created resource_field.created], drive: :resource_builder },
        'rls_operator_sql' => { none: 'compiles a rule to SQL text' },
        'rls_policy_generator' => { none: 'installs PostgreSQL row-level security policies (DDL); no permission data' },
        'security_audit' => { none: 'read-only review (the rake task records report.generated)' },
        'stale_assignment_auditor' => { none: 'read-only report (the rake task records report.generated)' },
        'unscoped_query_detector' => { none: 'reports unscoped queries (query.unscoped is a runtime event)' }
      }.freeze

      # Writers outside services/: admin/ files (found by the scan) and model
      # entry points (listed by hand).
      OTHER_WRITERS = {
        'admin/change_set' => { events: %w[permission_set.updated resource.updated resource_field.updated], drive: :change_set },
        'admin/column_fields' => { events: %w[resource_field.created], drive: :column_fields },
        'admin/permission_set_factory' => { events: CLONE_EVENTS, drive: :factory },
        'Resource.grant_full_access!' => { events: %w[resource.created resource_field.created], drive: :grant_full_access },
        'PermissionSet#deep_clone' => { events: CLONE_EVENTS, drive: :set_deep_clone },
        'PermissionSetGroup#deep_clone' => { events: GROUP_CLONE_EVENTS, drive: :group_deep_clone },
        'PermissionSetUser#mark_reviewed!' => { events: %w[assignment.reviewed], drive: :mark_reviewed }
      }.freeze

      RAKE_ACTOR = 'ops: Grace (TCK-9)'

      # task => { events:, drive: } | { none: }
      RAKE_TASKS = {
        'permission_forge:audit_events:purge' => { events: %w[audit.purged], drive: :rake_purge },
        'permission_forge:cache:clear' => { events: %w[cache.cleared], drive: :rake_cache_clear },
        'permission_forge:cleanup_expired_assignments' => { events: %w[assignment.revoked cleanup.expired_assignments],
                                                            drive: :rake_cleanup },
        'permission_forge:erasure' => { events: %w[assignment.revoked erasure.performed], drive: :rake_erasure },
        'permission_forge:audit' => { events: %w[report.generated], drive: :rake_audit },
        'permission_forge:audit_masks' => { events: %w[report.generated], drive: :rake_audit_masks },
        'permission_forge:expired_assignments' => { events: %w[report.generated], drive: :rake_expired_report },
        'permission_forge:stale_assignments' => { events: %w[report.generated], drive: :rake_stale_report },
        'permission_forge:rls:sync' => { none: 'installs PostgreSQL row-level security policies (DDL); no permission data' },
        'permission_forge:rls:status' => { none: 'prints policy drift; read-only' },
        'permission_forge:rls:remove' => { none: 'drops PostgreSQL row-level security policies (DDL); no permission data' }
      }.freeze

      WRITE_CALL = /\.(?:create!?|save!?|update!?|destroy!?|destroy_all|destroy_by|delete_all|delete_by|update_all|insert_all!?|upsert_all|
                    find_or_create_by!?|create_or_find_by!?|update_columns?|update_attribute|touch)(?![\w?])/x

      def self.service_key(path)
        relative = Pathname(path).relative_path_from(SERVICES_DIR).to_s.delete_suffix('.rb')
        relative.start_with?('concerns/') ? relative : relative.split('/').first
      end

      def self.service_files
        Dir[SERVICES_DIR.join('**/*.rb')]
      end

      # Writers named in the tables, called from another file (`PermissionSetCloner.call`).
      def self.writer_call
        names = SERVICES.reject { |_key, spec| spec[:none] }.keys.reject { |key| key.include?('/') }.map(&:camelize)
        /\b(?:#{names.join('|')})\.call\b|\.(?:deep_clone|grant_full_access!|mark_reviewed!)\b/
      end

      def self.writes?(path)
        File.read(path).lines.reject { |line| line.strip.start_with?('#') }.any? { |line| line.match?(WRITE_CALL) || line.match?(writer_call) }
      end

      setup do
        @admin = create_user(name: ADMIN_NAME, email: 'ada@acme.test')
        @ana = create_user(name: 'Ana Krasniqi', email: 'ana@acme.test')
        @bo = create_user(name: 'Bo Berisha', email: 'bo@acme.test')
        @set = create_permission_set(name: 'Sales rep')
        @resource = create_resource(permission_set: @set, read_access: true, edit_access: true)
        @email = create_resource_field(resource: @resource, name: 'email', read_access: true)
        @action = create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        @rule = create_permission_set_rule(permission_set: @set, resource: @resource, name: 'Own customers')
        @assignment = create_permission_set_user(user: @ana, permission_set: @set)
        @group = create_permission_set_group(name: 'Sales team')
        @set.update!(permission_set_group: @group)
      end

      # --- the tables cover the code ---------------------------------------------------

      test 'every service is listed with its events or the reason it writes nothing' do
        unlisted = self.class.service_files.map { |path| self.class.service_key(path) }.uniq - SERVICES.keys

        assert_empty unlisted, "services not in SERVICES of #{__FILE__}: say which audit events each writes " \
                               '(events:, drive:) or why it writes none (none:)'
        assert_empty SERVICES.keys - self.class.service_files.map { |path| self.class.service_key(path) }, 'stale SERVICES entries'
      end

      test 'a service or admin file that writes is listed as a writer' do
        files = self.class.service_files + Dir[ADMIN_DIR.join('**/*.rb')]
        writers = files.select { |path| self.class.writes?(path) }
        keys = writers.map { |path| path.start_with?(ADMIN_DIR.to_s) ? "admin/#{File.basename(path, '.rb')}" : self.class.service_key(path) }
        silent = keys.uniq.reject { |key| SERVICES.dig(key, :events) || OTHER_WRITERS.dig(key, :events) }

        assert_empty silent, "these files write but are not listed as writers in #{__FILE__} (give events: and a drive_ method)"
      end

      test 'every rake task is listed' do
        tasks = IntegrationSupport.rake_application.tasks.map(&:name) - ['environment']

        assert_empty tasks - RAKE_TASKS.keys, "rake tasks not in RAKE_TASKS of #{__FILE__}"
        assert_empty RAKE_TASKS.keys - tasks, 'stale RAKE_TASKS entries'
      end

      # --- every writer, driven ---------------------------------------------------------

      SERVICES.merge(OTHER_WRITERS).each do |key, spec|
        next if spec[:none]

        test "#{key} writes #{spec[:events].join(', ')} with the actor, the reason and one correlation id" do
          send(:"drive_#{spec[:drive]}")
          assert_call_recorded(key, spec[:events], expected_actor(:signed_in) + ['service', REASON])
        end
      end

      RAKE_TASKS.each do |task, spec|
        next if spec[:none]

        test "rake #{task} with ACTOR= and REASON= writes #{spec[:events].join(', ')}" do
          send(:"drive_#{spec[:drive]}")
          assert_call_recorded(task, spec[:events], ['system', nil, RAKE_ACTOR, 'rake', REASON])
        end
      end

      private

      # Captures the events written by the block (the call itself, not its arrangement).
      def capture(&)
        @call_events = ledger_events(&)
      end

      # Runs a writer as the admin, with the reason.
      def as_admin(&)
        capture { PermissionForge.with_audit_actor(user: @admin, reason: REASON, &) }
      end

      # `expected` is [actor_type, actor_id, actor_label, source, reason].
      def assert_call_recorded(key, names, expected)
        events = @call_events || flunk("drive for #{key} ran nothing through #capture")
        assert_equal names.sort, recorded_names(events), "#{key}: the events it writes (update the table if intended)"
        events.each do |event|
          assert_equal expected, event.attributes.values_at(*%w[actor_type actor_id actor_label source reason]),
                       "#{key}: #{event.event} ##{event.id} actor, source and reason"
        end
        assert_equal 1, events.map(&:correlation_id).uniq.size, "#{key}: one correlation id for the call"
        assert_tables_explained(key)
      end

      # The whole row as arranged (bookkeeping aside), and its Permission Set.
      def assert_snapshot(name, record)
        event = assert_audit_event(name, record_type: record.class.base_class.name, record_id: record.id.to_s)
        assert_equal whole_row(record.attributes.as_json), whole_row(event.data['snapshot']), "#{name}: whole row"
        set_id = record.try(:permission_set_id)
        assert_equal set_id, event.permission_set_id, "#{name}: permission_set_id" if set_id
      end

      def whole_row(attributes)
        attributes.except(*TableLedger::BOOKKEEPING)
      end

      def assert_copy_of(source, copy)
        assert_audit_event("#{source.class.audit_model_key}.cloned", record_id: copy.id.to_s, data: { 'source_uuid' => source.uuid })
      end

      # --- service drivers ----------------------------------------------------------------

      def drive_purger
        old = Audit.record('report.generated', data: { 'task' => 'old' }, occurred_at: 2.years.ago)
        capture { Services::AuditEventPurger.call(older_than: 1.year, actor: @admin, reason: REASON) }
        assert_not AuditEvent.exists?(old.id)
        assert_audit_event('audit.purged', data: { 'count' => 1 })
      end

      def drive_bulk_assignment
        as_admin do
          Services::BulkPermissionSetAssignment.call(permission_set: @set, user_ids: [@bo.id, @admin.id], action: :assign)
        end
        [@bo, @admin].each { |user| assert_audit_event('assignment.granted', subject_user_id: user.id.to_s) }
      end

      def drive_consent
        rows = %w[Newsletter Partners].map do |name|
          create_permission_set_user(user: @ana, permission_set: create_permission_set(name: name, requires_session_flag: 'marketing'))
        end
        capture { Services::ConsentWithdrawalHandler.call(user: @ana, consent_flag: 'marketing', actor: @admin, reason: REASON) }
        rows.each { |row| assert_snapshot('assignment.revoked', row) }
        assert_audit_event('consent.withdrawn', subject_user_id: @ana.id.to_s, data: { 'revoked' => 2 })
      end

      def drive_erasure
        membership = PermissionSetGroupUser.create!(permission_set_group: @group, user: @ana)
        capture { Services::DataSubjectErasure.call(user: @ana, actor: @admin, reason: REASON) }
        assert_snapshot('assignment.revoked', @assignment)
        assert_snapshot('group_membership.removed', membership)
        assert_audit_event('erasure.performed', subject_user_id: @ana.id.to_s, data: { 'dry_run' => false })
      end

      def drive_cache_clearer
        @ana.permissions_hash
        capture { Services::PermissionCacheClearer.call(actor: @admin, reason: REASON) }
        assert_nil PermissionForge.cache.read(@ana.permission_cache_key)
        assert_audit_event('cache.cleared', data: { 'operation' => 'cache_clear', 'unconfirmed' => 0 })
      end

      def drive_cleaner
        other = create_permission_set_user(user: @bo, permission_set: @set)
        [@assignment, other].each { |row| row.update_columns(expires_at: 1.day.ago) }
        capture { Services::ExpiredAssignmentCleaner.call(actor: @admin, reason: REASON) }
        [@assignment, other].each { |row| assert_snapshot('assignment.revoked', row) }
        assert_audit_event('cleanup.expired_assignments', data: { 'removed' => 2 })
      end

      def drive_set_cloner
        as_admin { Services::PermissionSetCloner.call(permission_set: @set, attrs: { name: 'Copy' }) }
        assert_copy_of(@set, PermissionSet.find_by!(name: 'Copy'))
      end

      def drive_group_cloner
        as_admin { Services::PermissionSetGroupCloner.call(permission_set_group: @group, attrs: { name: 'Sales copy' }) }
        assert_copy_of(@group, PermissionSetGroup.find_by!(name: 'Sales copy'))
      end

      def drive_field_generator
        as_admin { Services::ResourceFieldGenerator.call(resource: @resource) }
        assert_audit_event('resource_field.created', record_label: 'Customer.domain')
      end

      def drive_resource_builder
        as_admin { Services::ResourceWithFieldsBuilder.call(permission_set: @set, resource_name: 'Supplier') }
        assert_audit_event('resource.created', record_label: 'Supplier')
      end

      # --- other writers ------------------------------------------------------------------

      def drive_change_set
        params = { set: { description: 'Edited' }, resources: { @resource.id => { create_access: '1' } },
                   fields: { @email.id => { level: 'masked', mask_strategy: 'email' } } }
        as_admin { Admin::ChangeSet.new(permission_set: @set, params: params).apply! }
        event = assert_audit_event('resource_field.updated', record_id: @email.id.to_s)
        assert_equal [false, true], event.data.dig('changes', 'mask_access')
      end

      # Not atomic on its own: its callers (resources#create, resources#sync)
      # run it in their transaction, as here.
      def drive_column_fields
        as_admin { ActiveRecord::Base.transaction { Admin::ColumnFields.new(@resource, muting: false).create(%w[domain name], 'read') } }
        assert_audit_event('resource_field.created', record_label: 'Customer.domain')
      end

      def drive_factory
        as_admin { Admin::PermissionSetFactory.create({ name: 'Started from', is_muting: false }, source: @set) }
        assert_copy_of(@set, PermissionSet.find_by!(name: 'Started from'))
      end

      def drive_grant_full_access
        as_admin { Resource.grant_full_access!(permission_set: @set, resource_name: 'Supplier') }
        event = assert_audit_event('resource.created', record_label: 'Supplier')
        assert event.data.dig('snapshot', 'delete_access'), 'full access'
      end

      def drive_set_deep_clone
        as_admin { @set.deep_clone(name: 'Deep copy') }
        assert_copy_of(@set, PermissionSet.find_by!(name: 'Deep copy'))
      end

      def drive_group_deep_clone
        as_admin { @group.deep_clone(name: 'Deep group copy') }
        assert_copy_of(@group, PermissionSetGroup.find_by!(name: 'Deep group copy'))
      end

      def drive_mark_reviewed
        as_admin { @assignment.mark_reviewed!(reviewer: @admin) }
        assert_audit_event('assignment.reviewed', record_id: @assignment.id.to_s, data: { 'decision' => 'keep' })
        assert_equal @admin.id, @assignment.reload.reviewed_by_id
      end

      # --- rake drivers -------------------------------------------------------------------

      def run_rake(task, **env)
        with_env(env.merge('ACTOR' => RAKE_ACTOR, 'REASON' => REASON)) { capture { run_rake_task(task) } }
      end

      def drive_rake_purge
        Audit.record('report.generated', data: { 'task' => 'old' }, occurred_at: 2.years.ago)
        with_config(:audit_retention_period, 1.year) { run_rake('permission_forge:audit_events:purge') }
        assert_audit_event('audit.purged', data: { 'count' => 1 })
      end

      def drive_rake_cache_clear
        @ana.permissions_hash
        run_rake('permission_forge:cache:clear')
        assert_nil PermissionForge.cache.read(@ana.permission_cache_key)
        assert_audit_event('cache.cleared', data: { 'operation' => 'cache_clear' })
      end

      def drive_rake_cleanup
        @assignment.update_columns(expires_at: 1.day.ago)
        run_rake('permission_forge:cleanup_expired_assignments')
        assert_snapshot('assignment.revoked', @assignment)
      end

      def drive_rake_erasure
        run_rake('permission_forge:erasure', 'USER_ID' => @ana.id.to_s, 'DRY_RUN' => 'false')
        assert_audit_event('erasure.performed', subject_user_id: @ana.id.to_s)
      end

      def drive_rake_audit
        run_rake('permission_forge:audit')
        assert_audit_event('report.generated', data: { 'task' => 'permission_forge:audit' })
      end

      def drive_rake_audit_masks
        run_rake('permission_forge:audit_masks')
        assert_audit_event('report.generated', data: { 'task' => 'permission_forge:audit_masks' })
      end

      def drive_rake_expired_report
        run_rake('permission_forge:expired_assignments')
        assert_audit_event('report.generated', data: { 'task' => 'permission_forge:expired_assignments' })
      end

      def drive_rake_stale_report
        run_rake('permission_forge:stale_assignments')
        assert_audit_event('report.generated', data: { 'task' => 'permission_forge:stale_assignments' })
      end
    end
  end
end
