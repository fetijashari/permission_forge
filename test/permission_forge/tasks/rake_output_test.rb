require 'test_helper'
require 'rake'

module PermissionForge
  # What the rake tasks print and how they exit, as found in the 0.14.1 field
  # test (pf-showcase, e-operations and a-onboarding).
  class RakeOutputTest < ActiveSupport::TestCase
    TASK_FILES = %w[permission_forge permission_forge_expiration permission_forge_gdpr permission_forge_audit_events
                    permission_forge_cache permission_forge_rls].freeze
    ENV_KEYS = %w[ACTOR REASON USER_ID DRY_RUN FAIL_ON FORMAT].freeze

    def self.rake_application
      @rake_application ||= begin
        previous = Rake.application
        recording = Rake::TaskManager.record_task_metadata
        # As `rake -T` does: keep the descriptions (Task#comment is what it prints).
        Rake::TaskManager.record_task_metadata = true
        app = Rake.application = Rake::Application.new
        Rake::Task.define_task(:environment)
        TASK_FILES.each { |file| load PermissionForge::Engine.root.join("lib/tasks/#{file}.rake").to_s }
        Rake.application = previous
        Rake::TaskManager.record_task_metadata = recording
        app
      end
    end

    setup do
      @previous_rake = Rake.application
      Rake.application = self.class.rake_application
      Rake.application.tasks.each(&:reenable)
      @saved_env = ENV.to_h.slice(*ENV_KEYS)
      ENV_KEYS.each { |key| ENV.delete(key) }
      @user = create_user(name: 'Rae Rake')
      @set = create_permission_set(name: 'Rake Set')
      create_permission_set_user(user: @user, permission_set: @set)
    end

    teardown do
      Rake.application = @previous_rake
      ENV_KEYS.each { |key| ENV.delete(key) }
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

    def reports = PermissionForge::AuditEvent.unscoped.where(event: 'report.generated')

    # --- e-operations #6: FAIL_ON ------------------------------------------------------------

    test 'FAIL_ON says why it fails the build' do
      failing = PermissionForge::Services::SecurityAudit.call.at_least(:medium).size
      assert_predicate failing, :positive?, 'the suite configuration has a Medium finding (masked_nil_user_bypass)'
      ENV['FAIL_ON'] = 'medium'

      _out, err, status = run_task('permission_forge:audit')

      assert_equal 1, status
      assert_includes err, "Failing: #{failing} finding(s) at or above medium (FAIL_ON=medium)."
    end

    test 'FAIL_ON is read in any case' do
      ENV['FAIL_ON'] = 'MEDIUM'

      _out, err, status = run_task('permission_forge:audit')

      assert_equal 1, status
      assert_match(/at or above medium \(FAIL_ON=MEDIUM\)/, err)
    end

    test 'FAIL_ON with nothing at that level passes quietly' do
      audit = PermissionForge::Services::SecurityAudit
      original = audit.method(:call).unbind
      replace_singleton_method(audit, :call) { |*| audit::Report.new(findings: [], generated_at: Time.current, preset: :compat) }
      ENV['FAIL_ON'] = 'low'

      _out, err, status = run_task('permission_forge:audit')

      assert_nil status
      assert_empty err
    ensure
      replace_singleton_method(audit, :call, original)
    end

    test 'an unknown FAIL_ON stops before the review with exit 2 and the levels' do
      ENV['FAIL_ON'] = 'hihg'

      assert_no_difference -> { reports.count } do
        out, err, status = run_task('permission_forge:audit')

        assert_equal 2, status
        assert_empty out
        assert_includes err, 'FAIL_ON must be one of critical, high, medium, low, info (got "hihg")'
      end
    end

    test 'FORMAT=json keeps stdout parseable when FAIL_ON fails' do
      ENV.update('FAIL_ON' => 'medium', 'FORMAT' => 'json')

      out, err, status = run_task('permission_forge:audit')

      assert_equal 1, status
      assert_kind_of Hash, JSON.parse(out)
      assert_includes err, 'Failing:'
    end

    test 'SecurityAudit.severity_named reads a level in any case and nothing else' do
      audit = PermissionForge::Services::SecurityAudit

      assert_equal :high, audit.severity_named('HIGH')
      assert_equal :info, audit.severity_named(' info ')
      assert_equal :low, audit.severity_named(:low)
      assert_nil audit.severity_named('hihg')
      assert_nil audit.severity_named(nil)
    end

    # --- e-operations #20: rake -T shows the first sentence ------------------------------------

    # rake -T printed "... in the audit log (supports GDPR Art": a full stop after a word character ends
    # what it shows.
    test 'the erasure task description is not cut at an abbreviation' do
      comment = Rake::Task['permission_forge:erasure'].comment

      assert_includes comment, 'in the audit log (supports GDPR Article 17)'
      assert_not_includes comment, 'Art.'
    end

    test 'every task description shows a whole first sentence in rake -T' do
      described = Rake.application.tasks.select { |task| task.name.start_with?('permission_forge') && task.comment }
      assert_operator described.size, :>=, 10

      described.each do |task|
        comment = task.comment
        assert_equal comment.count('('), comment.count(')'), "#{task.name}: #{comment.inspect} is cut mid-sentence"
      end
    end

    # Field test: "Read-only security review" although every run writes report.generated, and
    # cache:clear opening with "(0.14)" upgrade text on a fresh install.
    # Task#comment is the first sentence, what rake -T shows.
    test 'the audit task says it changes no permission data and records the run' do
      assert_equal 'Security review of the PermissionForge setup: changes no permission data, records the run in ' \
                   'the audit log', Rake::Task['permission_forge:audit'].comment
    end

    test 'the cache:clear description leads with what it does, the upgrade hint last' do
      task = Rake::Task['permission_forge:cache:clear']

      assert_equal "Remove every user's cached permissions at once; each user rebuilds on their next request", task.comment
      assert task.full_comment.end_with?('(After an upgrade from 0.13: run it once the old processes are gone.)'),
             task.full_comment
    end

    # --- e-operations #45: erasure and the audit-log label scrub --------------------------------

    def labels_naming(user)
      events = PermissionForge::AuditEvent.unscoped
      [events.where(actor_type: 'user', actor_id: user.id.to_s).where.not(actor_label: nil).count,
       events.where(subject_user_id: user.id.to_s).where.not(record_label: nil).count]
    end

    test 'the erasure dry run says how many audit-log name labels it would clear' do
      actor, subject = labels_naming(@user)
      assert_predicate subject, :positive?, 'the assignment wrote an event about the user'
      ENV['USER_ID'] = @user.id.to_s

      out, = run_task('permission_forge:erasure')

      assert_includes out, "Audit log name labels to clear: #{actor} as actor, #{subject} as subject"
    end

    test 'the erasure says how many audit-log name labels it cleared' do
      ENV.update('USER_ID' => @user.id.to_s, 'DRY_RUN' => 'false', 'ACTOR' => 'dpo')

      out, = run_task('permission_forge:erasure')

      event = PermissionForge::AuditEvent.unscoped.where(event: 'erasure.performed').order(:id).last
      assert_includes out, "Audit log name labels cleared: #{event.data['actor_labels_cleared']} as actor, " \
                           "#{event.data['record_labels_cleared']} as subject"
      assert_predicate event.data['record_labels_cleared'], :positive?
      assert_equal [0, 0], labels_naming(@user)
    end
  end
end
