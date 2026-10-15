# frozen_string_literal: true

namespace :permission_forge do
  # Exits 1 when it finds stale assignments, 2 when THRESHOLD_DAYS is not a
  # number of days (rather than reading it as 0, which flags everything).
  desc 'Find permanent permission assignments not reviewed within THRESHOLD_DAYS ' \
       '(default: config.admin_stale_assignment_days, 90). Exits 1 when it finds any.'
  task stale_assignments: :environment do
    task_name = 'permission_forge:stale_assignments'
    threshold = ENV.fetch('THRESHOLD_DAYS', nil)&.then do |given|
      digits = given.strip
      # ASCII digits only: Integer() would also take Ruby's underscores ("1_0").
      days = Integer(digits, 10) if digits.match?(/\A[0-9]+\z/)
      next days if days&.between?(1, 36_500)

      message = "THRESHOLD_DAYS must be a whole number of days from 1 to 36500 (got #{given.inspect}). " \
                "Usage: rake #{task_name} THRESHOLD_DAYS=90"
      PermissionForge::RakeAudit.log(task_name, "refused: #{message}")
      warn message
      exit 2
    end
    result = PermissionForge::RakeAudit.reporting(
      task_name,
      counts: ->(r) { { stale: r[:stale_count], users: r[:affected_user_ids].size, threshold_days: r[:threshold_days] } }
    ) { PermissionForge::Services::StaleAssignmentAuditor.call(threshold_days: threshold) }

    if result[:stale_count].zero?
      puts "No stale assignments found (threshold: #{result[:threshold_days]} days)."
    else
      puts "Found #{result[:stale_count]} stale assignment(s) affecting #{result[:affected_user_ids].size} user(s):"
      result[:assignments].each do |a|
        puts "  User #{a[:user_id]} — #{a[:permission_set] || '(set not found)'} (#{a[:days_stale]} days since last review or grant)"
      end
      puts "\nConsider reviewing these assignments or setting expires_at for time-bound access."
      exit 1
    end
  end

  # Supports a GDPR Art. 17 erasure request (Services::DataSubjectErasure).
  # Removes the person's assignments and group memberships and their cached
  # permissions, and clears their name labels in the audit log. Run with no
  # tenant (as here), the labels go in every tenant. What stays: the ids, ip,
  # request id, reason and data of every audit event, the *_by_id columns on
  # rows the person created, edited or reviewed, and the person's own record
  # in the app. Assignments in other tenants stay when a tenant is current.
  # rake -T shows a description up to its first full stop: the first sentence
  # carries no abbreviation ("Article 17", not "Art. 17").
  desc "Remove a user's assignments, group memberships and cached permissions, and clear their name labels " \
       'in the audit log (supports GDPR Article 17). Ids and other event data stay. USER_ID required; ' \
       'DRY_RUN=true by default.'
  task erasure: :environment do
    user_id = ENV.fetch('USER_ID', nil)
    dry_run = ENV.fetch('DRY_RUN', 'true') == 'true'

    abort 'USER_ID is required. Usage: rake permission_forge:erasure USER_ID=123' if user_id.blank?

    user = PermissionForge.configuration.user_model.find_by(id: user_id)
    abort "User not found with ID: #{user_id}" if user.nil?

    task_name = 'permission_forge:erasure'
    # a dry run changes nothing and writes no event, so it needs no actor
    result = if dry_run
               PermissionForge::Services::DataSubjectErasure.call(user: user, dry_run: true)
             else
               PermissionForge::RakeAudit.changing(task_name) do
                 PermissionForge::Services::DataSubjectErasure.call(user: user)
               end
             end
    PermissionForge::RakeAudit.log(task_name, "user #{user_id}, dry_run=#{dry_run}: #{result.except(:permission_sets).to_json}")

    if dry_run
      puts "Dry run — would remove for user #{user_id}:"
      puts "  Permission set assignments: #{result[:assignments_count]}"
      puts "  Group assignments: #{result[:group_assignments_count]}"
      puts "  Permission sets: #{result[:permission_sets].join(', ')}" if result[:permission_sets].any?
      puts "  Audit log name labels to clear: #{result[:actor_labels_to_clear]} as actor, " \
           "#{result[:record_labels_to_clear]} as subject (plus those on the events the erasure writes)"
      puts "\nRun with DRY_RUN=false to execute."
    else
      puts "Erasure complete for user #{user_id}:"
      puts "  Assignments removed: #{result[:assignments_removed]}"
      puts "  Group assignments removed: #{result[:group_assignments_removed]}"
      puts "  Audit log name labels cleared: #{result[:actor_labels_cleared]} as actor, " \
           "#{result[:record_labels_cleared]} as subject"
      puts "  Cache cleared: #{result[:cache_cleared]}"
      puts "  Assignments remaining in other tenants: #{result[:assignments_remaining_elsewhere]}"
      puts '  Kept: audit event ids, ip, request id, reason and data; *_by_id columns; the user record itself.'
    end
  end
end
