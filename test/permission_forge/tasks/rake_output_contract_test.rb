# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/rake_tasks'
require_relative '../../support/static_guard'

module PermissionForge
  module Tasks
    # G3c. What a data-changing task prints comes from the same structure its
    # summary event records (PermissionForge::RakeOutput): every key of the
    # event's data is named in the output (ENVELOPE: the keys the title or
    # another line carries, each with its reason), the cache outcome says
    # when the store lives in this rake process only (Cache::Outcome) and not
    # on a shared store, people are named as the admin names them — never
    # "User 2" or a bare id list — and a dry run says "would".
    #
    # CHANGING lists every task that goes through RakeAudit.changing, with
    # the summary event it records and a fixture; the count of
    # `RakeAudit.changing(` calls in lib/tasks must match, so a new changing
    # task gets a contract here or fails.
    class RakeOutputContractTest < ActiveSupport::TestCase
      include RakeTasks::Case

      CHANGING = {
        'permission_forge:cache:clear' => { event: 'cache.cleared', env: {} },
        'permission_forge:cleanup_expired_assignments' => { event: 'cleanup.expired_assignments', env: {} },
        'permission_forge:erasure' => { event: 'erasure.performed', env: { 'DRY_RUN' => 'false' } },
        'permission_forge:audit_events:purge' => { event: 'audit.purged', env: {} }
      }.freeze

      # Event data keys the output carries without a line of their own.
      ENVELOPE = {
        'operation' => 'the title says what ran',
        'dry_run' => 'the title says "Dry run — would" for a dry run',
        'subject_user_id' => 'the title names the person',
        'across_tenants' => 'a rake run always covers every tenant (AcrossTenants)',
        'tenants' => 'the per-tenant count of a summary; cache:clear prints its own',
        'counted' => 'under the pattern strategy the "User visits invalidated" line says "not counted"',
        'set_uuids' => 'the sets are printed by name',
        'group_uuids' => 'the groups are printed by name',
        'affected_user_count' => 'the people are printed, with their count',
        'affected_user_ids_truncated' => 'a bound of the list the event stores; the output prints every person',
        'batch' => 'one audit.purged per deletion batch; the output gives the total',
        'count' => 'per batch; the output gives the total (Audit events deleted)'
      }.freeze

      PEOPLE_AS_IDS = /\bUser \d+|\bUser IDs?:|\buser_ids?\b/i

      setup do
        @user = create_user(name: 'Rae Rake', email: 'rae@acme.test')
        @set = create_permission_set(name: 'Rake Set')
        create_permission_set_user(user: @user, permission_set: @set)
        @old_retention = PermissionForge.configuration.audit_retention_period
      end

      teardown do
        PermissionForge.configuration.audit_retention_period = @old_retention
        PermissionForge.configuration.cache_backend = :memory
        PermissionForge.configuration.reset_cache_store!
      end

      # What each changing task needs in place (run as the test).
      FIXTURES = {
        'permission_forge:cleanup_expired_assignments' => lambda do
          expire_assignments_of(@user)
          create_permission_set_user(user: @user, permission_set: create_permission_set(name: "Rake #{SecureRandom.hex(2)}"))
        end,
        'permission_forge:erasure' => -> { ENV['USER_ID'] = @user.id.to_s },
        'permission_forge:audit_events:purge' => lambda do
          PermissionForge.configuration.audit_retention_period = 30.days
          PermissionForge::AuditEvent.unscoped.where(event: 'assignment.granted').update_all(occurred_at: 40.days.ago)
        end
      }.freeze

      def expire_assignments_of(user)
        PermissionForge::PermissionSetUser.where(user_id: user.id).find_each { |psu| psu.update_columns(expires_at: 1.day.ago) }
      end

      # Runs the task with ACTOR and its fixture; answers its stdout and the
      # summary event it recorded.
      def run_changing(task)
        ENV['ACTOR'] = 'ops: TCK-12'
        ENV.update(CHANGING.fetch(task)[:env])
        FIXTURES[task]&.then { |fixture| instance_exec(&fixture) }
        before = PermissionForge::AuditEvent.unscoped.maximum(:id) || 0
        out, err, status = run_task(task)
        assert_nil status, "#{task} exited #{status}: #{err}"
        [out, summary_event_after(task, before, out)]
      end

      def summary_event_after(task, before, out)
        name = CHANGING.fetch(task)[:event]
        event = PermissionForge::AuditEvent.unscoped.where(event: name).where('id > ?', before).order(:id).last
        assert event, "#{task} recorded no #{name}: #{out}"
        event
      end

      def process_local_lead
        PermissionForge::RakeOutput::PROCESS_LOCAL_NOTE.split(/[—:]/).first.strip
      end

      # The event data keys (ENVELOPE aside) whose label is not in the output.
      def self.unprinted(data_keys, out)
        (data_keys - ENVELOPE.keys).reject { |key| out.include?(PermissionForge::RakeOutput.label(key)) }
      end

      test 'negative fixture: an output that leaves a recorded key out is caught, "User N" too' do
        out = "Removed 1 expired assignment(s):\n  Expired assignments removed: 1\n  User IDs: 1\n"

        assert_equal %w[invalidated set_names], self.class.unprinted(%w[operation removed invalidated set_names], out)
        assert_match PEOPLE_AS_IDS, out
        assert_match PEOPLE_AS_IDS, 'User 2 — Sales (120 days since last review or grant)'
        assert_no_match PEOPLE_AS_IDS, 'Rae Rake (id 2) — Sales'
      end

      test 'CHANGING names every task that goes through RakeAudit.changing' do
        calls = StaticGuard.all_hits(globs: %w[lib/tasks/**/*.rake], needle: /RakeAudit\.changing\(/)

        assert_equal CHANGING.size, calls.size, calls.map(&:to_s).inspect
        changing = RakeTasks.tasks.select { |task| RakeTasks.body_of(task).match?(/RakeAudit\.changing\(/) }
        assert_equal CHANGING.keys.sort, changing.map(&:name).sort
      end

      test 'ENVELOPE names only keys some summary event records' do
        recorded = CHANGING.keys.flat_map { |task| run_changing(task).last.data.keys }.uniq
        stale = ENVELOPE.keys - recorded

        assert_empty stale, "no summary event records #{stale.join(', ')}: drop them from ENVELOPE"
        ENVELOPE.each_value { |reason| assert_predicate reason.strip, :present? }
      end

      CHANGING.each_key do |task|
        test "#{task} prints every key its summary event records, on the memory store with the process-local note" do
          out, event = run_changing(task)

          missing = self.class.unprinted(event.data.keys, out)
          assert_empty missing, "#{task} does not print #{missing.join(', ')} (data: #{event.data.inspect}):\n#{out}"
          assert_no_match PEOPLE_AS_IDS, out
          next unless event.data.key?('process_local')

          assert_includes out, process_local_lead, out
          assert_equal true, event.data['process_local']
        end

        test "#{task} on a shared store prints no process-local note" do
          Dir.mktmpdir do |dir|
            PermissionForge.configuration.cache_backend = ActiveSupport::Cache::FileStore.new(dir)
            PermissionForge.configuration.reset_cache_store!

            out, event = run_changing(task)

            assert_not_includes out, process_local_lead, out
            assert_equal false, event.data['process_local'] if event.data.key?('process_local')
          end
        end
      end

      test 'the erasure dry run says what it would do, with the same labels, and names the person' do
        ENV['USER_ID'] = @user.id.to_s

        out, = run_task('permission_forge:erasure')

        assert_match(/\ADry run — would .*Rae Rake/, out)
        assert_includes out, PermissionForge::RakeOutput.label('assignments_count')
        assert_includes out, PermissionForge::RakeOutput.label('permission_sets')
        assert_no_match PEOPLE_AS_IDS, out
      end

      test 'the reporting tasks name people as the admin does' do
        expire_assignments_of(@user)
        out, = run_task('permission_forge:expired_assignments')
        assert_includes out, 'Rae Rake'
        assert_no_match PEOPLE_AS_IDS, out

        create_permission_set_user(user: @user, permission_set: create_permission_set(name: 'Old Set')).update_columns(created_at: 100.days.ago)
        out, status = run_task('permission_forge:stale_assignments').values_at(0, 2)
        assert_equal 1, status, 'a permanent assignment not reviewed for 100 days is stale'
        assert_includes out, 'Rae Rake'
        assert_no_match PEOPLE_AS_IDS, out
      end

      test 'a person the people list does not know is printed as an id, never as "User N"' do
        config = PermissionForge.configuration
        config.user_list_resolver = -> { config.user_model.where.not(id: @user.id).order(:id) }
        expire_assignments_of(@user)

        out, = run_task('permission_forge:expired_assignments')

        assert_includes out, "id #{@user.id} (not in the people list)"
        assert_no_match PEOPLE_AS_IDS, out
      end
    end
  end
end
