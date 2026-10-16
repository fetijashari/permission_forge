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

  module_function

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
    first = lines[line - 1]
    indent = first[/\A */].size
    last = (line...lines.size).find { |index| index > line - 1 && lines[index].match?(/\A {#{indent}}end\b/) } || lines.size - 1
    lines[(line - 1)..last].join
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
