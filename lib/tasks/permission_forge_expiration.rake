# frozen_string_literal: true

namespace :permission_forge do
  # Prints the result the cleanup.expired_assignments event records
  # (RakeOutput): the people by name, the sets, the cache outcome.
  desc "Remove expired permission set assignments and invalidate affected users' cached permissions. " \
       'ACTOR= names who ran it, REASON= why.'
  task cleanup_expired_assignments: :environment do
    task_name = 'permission_forge:cleanup_expired_assignments'
    result = PermissionForge::RakeAudit.changing(task_name) { PermissionForge::Services::ExpiredAssignmentCleaner.call }
    PermissionForge::RakeAudit.log(task_name, "removed #{result[:removed]}, invalidated #{result[:invalidated]}")
    if result[:removed].zero?
      puts 'No expired assignments found.'
    else
      PermissionForge::RakeOutput.report("Removed #{result[:removed]} expired assignment(s):", result)
    end
  end

  desc 'List expired permission set assignments without removing them, as a dry run. ' \
       'ACTOR= names who ran it, REASON= why (recorded as report.generated).'
  task expired_assignments: :environment do
    result = PermissionForge::RakeAudit.reporting(
      'permission_forge:expired_assignments',
      counts: ->(r) { { expired: r[:expired_count], users: r[:affected_user_ids].size } }
    ) { PermissionForge::Services::ExpiredAssignmentCleaner.call(dry_run: true) }
    if result[:expired_count].zero?
      puts 'No expired assignments found.'
    else
      PermissionForge::RakeOutput.report(
        "Dry run — would remove #{result[:expired_count]} expired assignment(s) affecting #{result[:affected_user_ids].size} person(s):",
        result.slice(:expired_count, :affected_user_ids)
      )
      puts 'Run `rake permission_forge:cleanup_expired_assignments` to remove them.'
    end
  end
end
