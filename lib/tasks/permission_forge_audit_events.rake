# frozen_string_literal: true

namespace :permission_forge do
  namespace :audit_events do
    # Prints the result the audit.purged events record (RakeOutput).
    desc 'Delete audit events older than config.audit_retention_period. Deletes when DRY_RUN is unset or ' \
         'false (or 0, no); any other DRY_RUN value (1, true, yes) only counts. ACTOR= names who ran it, REASON= why.'
    task purge: :environment do
      task_name = 'permission_forge:audit_events:purge'
      dry_run = PermissionForge::RakeDryRun.dry_run?(ENV.fetch('DRY_RUN', nil), default: false)
      purge = -> { PermissionForge::Services::AuditEventPurger.call(dry_run: dry_run) }
      result = begin
        dry_run ? purge.call : PermissionForge::RakeAudit.changing(task_name, &purge)
      rescue PermissionForge::ConfigurationError => e
        warn "Refused: #{e.message}"
        PermissionForge::RakeAudit.log(task_name, "refused: #{e.message}")
        exit 1
      end
      PermissionForge::RakeAudit.log(task_name, result.to_json)

      if !result[:retention_configured]
        puts 'Retention is not configured (config.audit_retention_period is nil): nothing was deleted.'
      elsif dry_run
        PermissionForge::RakeOutput.report("Dry run — would delete #{result[:purged]} audit event(s) older than " \
                                           "#{result[:cutoff].iso8601}:", result.except(:dry_run))
      else
        PermissionForge::RakeOutput.report("Deleted #{result[:purged]} audit event(s) older than #{result[:cutoff].iso8601}:",
                                           result.except(:dry_run))
      end
    end
  end
end
