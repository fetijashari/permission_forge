# frozen_string_literal: true

require 'rake'

# The gem's rake tasks loaded once per process into their own Rake
# application, with the descriptions kept (Task#comment is what `rake -T`
# prints), for the tests that run or lint them.
#
#   class MyTaskTest < ActiveSupport::TestCase
#     include RakeTasks::Case
#     test '...' do
#       out, err, status = run_task('permission_forge:erasure')
#     end
#   end
module RakeTasks
  FILES = %w[permission_forge permission_forge_expiration permission_forge_gdpr permission_forge_audit_events
             permission_forge_cache permission_forge_rls].freeze
  # The ENV the tasks read; cleared around every test.
  ENV_KEYS = %w[ACTOR REASON USER_ID DRY_RUN FAIL_ON FORMAT THRESHOLD_DAYS].freeze
  # A literal read of a variable in a task body.
  ENV_READ = /\bENV(?:\.fetch\(|\[|\.key\?\()\s*['"]([A-Z_]+)['"]/
  # What PermissionForge::RakeAudit reads for a task that runs through it.
  RAKE_AUDIT_READS = %w[ACTOR REASON].freeze
  RAKE_AUDIT_CALL = /RakeAudit\.(?:changing|reporting)\(/

  module_function

  # The environment variables a task body reads: its literal ENV reads, plus
  # ACTOR and REASON when it runs through RakeAudit (which reads them).
  #
  # @param body [String] the source of the task's block
  # @return [Array<String>] sorted
  def env_keys_read(body)
    keys = body.scan(ENV_READ).flatten
    keys += RAKE_AUDIT_READS if body.match?(RAKE_AUDIT_CALL)
    keys.uniq.sort
  end

  def application
    @application ||= begin
      previous = Rake.application
      recording = Rake::TaskManager.record_task_metadata
      Rake::TaskManager.record_task_metadata = true
      app = Rake.application = Rake::Application.new
      Rake::Task.define_task(:environment)
      FILES.each { |file| load PermissionForge::Engine.root.join("lib/tasks/#{file}.rake").to_s }
      app
    ensure
      Rake.application = previous
      Rake::TaskManager.record_task_metadata = recording
    end
  end

  # @return [Array<Rake::Task>] every task of the gem, by name
  def tasks
    application.tasks.select { |task| task.name.start_with?('permission_forge:') }.sort_by(&:name)
  end

  # The source of one task's block: from its `task` line to the `end` at the
  # same indentation.
  #
  # @return [String]
  def body_of(task)
    file, line = task.actions.first.source_location
    lines = File.readlines(file)
    lines[(line - 1)..closing_line(lines, line - 1)].join
  end

  # The index of the `end` at the indentation of the line at `start`, or the
  # last line.
  def closing_line(lines, start)
    indent = lines[start][/\A */].size
    ((start + 1)...lines.size).find { |index| lines[index].match?(/\A {#{indent}}end\b/) } || (lines.size - 1)
  end

  # Setup and teardown for a test that runs the tasks.
  module Case
    extend ActiveSupport::Concern

    included do
      setup do
        @previous_rake = Rake.application
        Rake.application = RakeTasks.application
        Rake.application.tasks.each(&:reenable)
        @saved_env = ENV.to_h.slice(*RakeTasks::ENV_KEYS)
        RakeTasks::ENV_KEYS.each { |key| ENV.delete(key) }
      end

      teardown do
        Rake.application = @previous_rake
        RakeTasks::ENV_KEYS.each { |key| ENV.delete(key) }
        @saved_env.each { |key, value| ENV[key] = value }
      end
    end

    # @return [Array(String, String, Integer, nil)] stdout, stderr, the exit status (nil: none)
    def run_task(name)
      status = nil
      out, err = capture_io do
        Rake::Task[name].reenable
        Rake::Task[name].invoke
      rescue SystemExit => e
        status = e.status
      end
      [out, err, status]
    end
  end
end
