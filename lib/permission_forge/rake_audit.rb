# frozen_string_literal: true

module PermissionForge
  # What every rake task of the gem does about the audit log: names who ran it
  # (ACTOR=, stored as actor_label with actor_type 'system' and source 'rake'),
  # records `report.generated` for the read-only ones, and logs through
  # Rails.logger. The tasks' own output is untouched.
  #
  #   PermissionForge::RakeAudit.changing('permission_forge:erasure') { ... }   # warns without ACTOR
  #   PermissionForge::RakeAudit.reporting('permission_forge:audit', counts: ->(r) { r.counts }) { report }
  #
  # @api private
  module RakeAudit
    class << self
      # A task that changes data. Without ACTOR the label is "rake <task>" and
      # a warning is printed.
      def changing(task, env: ENV, warn_io: $stderr, &)
        warn_io.puts(missing_actor_warning(task)) if env['ACTOR'].blank? && warn_io
        run(task, env, &)
      end

      # A read-only task: runs the block (it returns the task's result), records
      # `report.generated` (task name, counts of that result) and returns the
      # result — before the task prints or exits.
      def reporting(task, counts:, env: ENV)
        run(task, env) do
          result = yield
          record_report(task, counts.call(result))
          result
        end
      end

      def label(task, env = ENV)
        env['ACTOR'].presence || "rake #{task}"
      end

      # One line in the application log.
      def log(task, message)
        Rails.logger&.info("[permission_forge] #{task}: #{message}")
      end

      # What a task that invalidated cached permissions adds to its output
      # when the store lives in its own process only (an in-memory store,
      # Cache::Base#process_local?): the running servers kept theirs. Empty
      # for a shared store.
      #
      # @return [String]
      def process_local_note(cache = PermissionForge.cache)
        return '' unless cache.process_local?

        ' (in this rake process only: an in-memory store — cache_backend :memory, or :memory_store — lives in ' \
          'each process, so the web and job processes keep their cached permissions until they restart or the ' \
          'entries expire (cache_ttl))'
      end

      private

      # A report must never fail because its own event cannot be written: the
      # failure is reported (Rails.error, the log) and the task goes on.
      def record_report(task, counts)
        PermissionForge::Audit.record('report.generated', data: { 'task' => task, 'counts' => counts.as_json })
      rescue StandardError => e
        PermissionForge::Audit::Failure.handle(e, strategy: :report, operation: :store, event: 'report.generated', task: task)
      end

      def run(task, env, &)
        actor = label(task, env)
        log(task, "run by #{actor}")
        context = { actor: PermissionForge::Audit::Actor.system(actor), source: 'rake', reason: env['REASON'].presence }
        PermissionForge::Audit::Context.with(**context, &)
      end

      def missing_actor_warning(task)
        "WARNING: ACTOR is not set; recorded as \"rake #{task}\". Usage: rake #{task} ACTOR=\"your name or ticket\""
      end
    end
  end
end
