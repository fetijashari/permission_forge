require 'test_helper'
require 'rake'

module PermissionForge
  # T6: the data-changing rake tasks take ACTOR=, the report tasks record report.generated.
  class AuditRakeTasksTest < ActiveSupport::TestCase
    TASK_FILES = %w[permission_forge permission_forge_expiration permission_forge_gdpr permission_forge_audit_events].freeze

    # The task files are loaded once per process (reloading them each test
    # resets their coverage counters).
    def self.rake_application
      @rake_application ||= begin
        previous = Rake.application
        app = Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        TASK_FILES.each { |file| load PermissionForge::Engine.root.join("lib/tasks/#{file}.rake").to_s }
        Rake.application = previous
        app
      end
    end

    setup do
      @previous_rake = Rake.application
      Rake.application = self.class.rake_application
      Rake.application.tasks.each(&:reenable)
      @saved_env = ENV.to_h.slice('ACTOR', 'REASON', 'USER_ID', 'DRY_RUN', 'THRESHOLD_DAYS')
      %w[ACTOR REASON USER_ID DRY_RUN THRESHOLD_DAYS].each { |key| ENV.delete(key) }
      @user = create_user(name: 'Rae Rake')
      @set = create_permission_set(name: 'Rake Set')
      @assignment = create_permission_set_user(user: @user, permission_set: @set)
    end

    teardown do
      Rake.application = @previous_rake
      %w[ACTOR REASON USER_ID DRY_RUN THRESHOLD_DAYS].each { |key| ENV.delete(key) }
      @saved_env.each { |key, value| ENV[key] = value }
    end

    def run_task(name)
      status = nil
      out, err = capture_io do
        Rake::Task[name].invoke
      rescue SystemExit => e
        status = e.status
      end
      [out, err, status]
    end

    def last_event(name) = PermissionForge::AuditEvent.where(event: name).order(:id).last

    test 'cleanup with ACTOR stores the label as a system actor from rake' do
      @assignment.update_columns(expires_at: 1.day.ago)
      ENV['ACTOR'] = 'ops: TCK-12'

      _, err, = run_task('permission_forge:cleanup_expired_assignments')

      assert_empty err
      event = last_event('cleanup.expired_assignments')
      assert_equal ['system', 'ops: TCK-12', 'rake'], [event.actor_type, event.actor_label, event.source]
      assert_nil event.actor_id
      assert_equal 'ops: TCK-12', last_event('assignment.revoked').actor_label
    end

    test 'cleanup without ACTOR is labelled with the task name and warns' do
      @assignment.update_columns(expires_at: 1.day.ago)

      out, err, = run_task('permission_forge:cleanup_expired_assignments')

      assert_includes err, 'ACTOR is not set'
      assert_includes out, 'Removed 1 expired assignment(s)'
      assert_equal 'rake permission_forge:cleanup_expired_assignments', last_event('cleanup.expired_assignments').actor_label
    end

    test 'erasure dry run writes no event and needs no actor' do
      ENV['USER_ID'] = @user.id.to_s

      assert_no_difference -> { PermissionForge::AuditEvent.count } do
        out, err, = run_task('permission_forge:erasure')

        assert_empty err
        assert_includes out, 'Dry run'
      end
    end

    test 'erasure for real records the summary with the ACTOR' do
      ENV.update('USER_ID' => @user.id.to_s, 'DRY_RUN' => 'false', 'ACTOR' => 'dpo', 'REASON' => 'ticket 3')

      run_task('permission_forge:erasure')

      event = last_event('erasure.performed')
      assert_equal ['dpo', 'rake', 'ticket 3'], [event.actor_label, event.source, event.reason]
      assert_equal 0, PermissionForge::PermissionSetUser.where(user: @user).count
    end

    test 'purge task deletes through the service, supports DRY_RUN and ACTOR' do
      PermissionForge.configuration.audit_retention_period = 30.days
      old = PermissionForge::Audit.record('report.generated', occurred_at: 90.days.ago, data: {})

      ENV['DRY_RUN'] = '1'
      out, = run_task('permission_forge:audit_events:purge')
      assert_includes out, 'Dry run'
      assert PermissionForge::AuditEvent.unscoped.exists?(old.id)

      Rake::Task['permission_forge:audit_events:purge'].reenable
      ENV.update('DRY_RUN' => '0', 'ACTOR' => 'retention')
      out, = run_task('permission_forge:audit_events:purge')
      assert_includes out, 'Deleted'
      assert_not PermissionForge::AuditEvent.unscoped.exists?(old.id)
      assert_equal 'retention', last_event('audit.purged').actor_label
    end

    test 'purge task without a period says retention is not configured' do
      out, = run_task('permission_forge:audit_events:purge')

      assert_includes out, 'Retention is not configured'
    end

    test 'purge task without ACTOR warns' do
      _, err, = run_task('permission_forge:audit_events:purge')

      assert_includes err, 'ACTOR is not set'
    end

    # Review of the round-7 fixes (P2-5): a model the application has not
    # loaded is not seen (EncryptedAttributes: an STI subclass's `encrypts`,
    # models_on), and a rake task boots without eager loading. The audit
    # loads the application's models first, through the admin's one
    # definition (ModelCatalog.eager_load_app_models).
    test 'the audit loads the application models before it reviews' do
      calls = []
      original = Services::SecurityAudit.method(:call)
      catalog = Admin::ModelCatalog
      original_load = catalog.method(:eager_load_app_models) if catalog.respond_to?(:eager_load_app_models)
      replace_singleton_method(catalog, :eager_load_app_models) { calls << :eager_load }
      replace_singleton_method(Services::SecurityAudit, :call) do |**kwargs|
        calls << :audit
        original.call(**kwargs)
      end

      run_task('permission_forge:audit')
      assert_equal %i[eager_load audit], calls
    ensure
      replace_singleton_method(Services::SecurityAudit, :call, original)
      if original_load
        replace_singleton_method(catalog, :eager_load_app_models, original_load)
      else
        catalog.singleton_class.send(:remove_method, :eager_load_app_models)
      end
    end

    test 'report tasks record report.generated with the task name and counts' do
      run_task('permission_forge:audit')
      event = last_event('report.generated')
      assert_equal 'permission_forge:audit', event.data['task']
      assert_equal 'rake permission_forge:audit', event.actor_label
      assert_kind_of Hash, event.data['counts']

      run_task('permission_forge:stale_assignments')
      assert_equal 'permission_forge:stale_assignments', last_event('report.generated').data['task']
      assert_equal 0, last_event('report.generated').data['counts']['stale']

      run_task('permission_forge:audit_masks')
      assert_equal 'permission_forge:audit_masks', last_event('report.generated').data['task']

      run_task('permission_forge:expired_assignments')
      assert_equal 'permission_forge:expired_assignments', last_event('report.generated').data['task']
    end

    test 'a report that exits 1 is recorded before the exit' do
      # staleness counts from the last review, else the grant (created_at)
      @assignment.update_columns(created_at: 200.days.ago, updated_at: 200.days.ago)

      _, _, status = run_task('permission_forge:stale_assignments')

      assert_equal 1, status
      assert_equal 1, last_event('report.generated').data['counts']['stale']
    end

    test 'the stale assignments report counts days since the last review or grant' do
      @assignment.update_columns(created_at: 200.days.ago, updated_at: 200.days.ago)

      out, = run_task('permission_forge:stale_assignments')

      assert_match(/\(200 days since last review or grant\)/, out)
    end

    test 'stale_assignments without THRESHOLD_DAYS uses admin_stale_assignment_days' do
      @assignment.update_columns(created_at: 40.days.ago, updated_at: 40.days.ago)

      out, = run_task('permission_forge:stale_assignments')
      assert_includes out, 'No stale assignments found (threshold: 90 days).'

      PermissionForge.configuration.admin_stale_assignment_days = 30
      Rake::Task['permission_forge:stale_assignments'].reenable
      _, _, status = run_task('permission_forge:stale_assignments')

      assert_equal 1, status
      assert_equal({ 'stale' => 1, 'users' => 1, 'threshold_days' => 30 }, last_event('report.generated').data['counts'])
    end

    test 'stale_assignments takes a THRESHOLD_DAYS of whole days' do
      @assignment.update_columns(created_at: 40.days.ago, updated_at: 40.days.ago)
      ENV['THRESHOLD_DAYS'] = ' 30 '

      out, _, status = run_task('permission_forge:stale_assignments')

      assert_equal 1, status
      assert_match(/\(40 days since last review or grant\)/, out)
      assert_equal 30, last_event('report.generated').data.dig('counts', 'threshold_days')
    end

    # Read with to_i, these were 0 days: every permanent assignment reported.
    test 'stale_assignments refuses a THRESHOLD_DAYS that is not a number of days' do
      ['', 'abc', '-3', '0', '1.5', '36501', '1_0'].each do |given|
        ENV['THRESHOLD_DAYS'] = given
        Rake::Task['permission_forge:stale_assignments'].reenable

        assert_no_difference -> { PermissionForge::AuditEvent.unscoped.where(event: 'report.generated').count } do
          out, err, status = run_task('permission_forge:stale_assignments')

          assert_equal 2, status, "THRESHOLD_DAYS=#{given.inspect}"
          assert_empty out
          assert_includes err, "THRESHOLD_DAYS must be a whole number of days from 1 to 36500 (got #{given.inspect})"
        end
      end
    end

    test 'tasks log through Rails.logger' do
      io = StringIO.new
      previous = Rails.logger
      Rails.logger = Logger.new(io)
      begin
        run_task('permission_forge:cleanup_expired_assignments')
      ensure
        Rails.logger = previous
      end

      assert_includes io.string, '[permission_forge] permission_forge:cleanup_expired_assignments'
    end

    test 'a report still prints when its report.generated event cannot be written' do
      klass = PermissionForge::AuditEvent.singleton_class
      klass.alias_method(:__orig_store!, :store!)
      klass.define_method(:store!) { |_attrs| raise ActiveRecord::StatementInvalid, 'boom' }
      ENV['FORMAT'] = 'json'

      out, _err, status = run_task('permission_forge:audit')

      assert_nil status
      assert_equal('counts', JSON.parse(out).keys.find { |key| key == 'counts' })
    ensure
      ENV.delete('FORMAT')
      replace_method(klass, :store!, klass.instance_method(:__orig_store!))
      klass.remove_method(:__orig_store!)
    end

    test 'purge task with auditing off prints the refusal and exits non-zero' do
      PermissionForge.configuration.audit_retention_period = 30.days
      PermissionForge.configuration.audit_events = false

      _out, err, status = run_task('permission_forge:audit_events:purge')

      assert_equal 1, status
      assert_includes err, 'Refused'
    end
  end
end
