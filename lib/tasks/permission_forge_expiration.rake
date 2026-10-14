# frozen_string_literal: true

namespace :permission_forge do
  desc 'Remove expired permission set assignments and invalidate affected users\' cached permissions'
  task cleanup_expired_assignments: :environment do
    task_name = 'permission_forge:cleanup_expired_assignments'
    result = PermissionForge::RakeAudit.changing(task_name) { PermissionForge::Services::ExpiredAssignmentCleaner.call }
    PermissionForge::RakeAudit.log(task_name, "removed #{result[:removed]}, invalidated #{result[:invalidated]}")
    if result[:removed].zero?
      puts 'No expired assignments found.'
    else
      puts "Removed #{result[:removed]} expired assignment(s), invalidated #{result[:invalidated]} user(s)."
    end
  end

  desc 'Show expired permission set assignments without removing (dry run)'
  task expired_assignments: :environment do
    result = PermissionForge::RakeAudit.reporting(
      'permission_forge:expired_assignments',
      counts: ->(r) { { expired: r[:expired_count], users: r[:affected_user_ids].size } }
    ) { PermissionForge::Services::ExpiredAssignmentCleaner.call(dry_run: true) }
    if result[:expired_count].zero?
      puts 'No expired assignments found.'
    else
      puts "Found #{result[:expired_count]} expired assignment(s) affecting #{result[:affected_user_ids].size} user(s)."
      puts "User IDs: #{result[:affected_user_ids].join(', ')}"
      puts 'Run `rake permission_forge:cleanup_expired_assignments` to remove them.'
    end
  end
end
