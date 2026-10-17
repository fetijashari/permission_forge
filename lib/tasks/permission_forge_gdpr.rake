# frozen_string_literal: true

namespace :permission_forge do
  # Exits 1 when it finds stale assignments, 2 when THRESHOLD_DAYS is not a
  # number of days (rather than reading it as 0, which flags everything).
  # People are named as the admin names them (RakeOutput.people).
  desc 'Find permanent assignments not reviewed in THRESHOLD_DAYS, by default admin_stale_assignment_days. ' \
       'Exits 1 when it finds any. ACTOR= names who ran it, REASON= why (recorded as report.generated).'
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
      puts "Found #{result[:stale_count]} stale assignment(s) affecting #{result[:affected_user_ids].size} person(s):"
      names = PermissionForge::RakeOutput.people(result[:assignments].map { |a| a[:user_id] })
      result[:assignments].each do |a|
        puts "  #{names.fetch(a[:user_id].to_s)} — #{a[:permission_set] || '(set not found)'} (#{a[:days_stale]} days since last review or grant)"
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
  # rake -T shows a description up to its first full stop after a word: the
  # first sentence carries no abbreviation ("Article 17", not "Art. 17") and
  # ends on a word, not a parenthesis. What it prints is the result the
  # erasure.performed event records (RakeOutput), the cache outcome included.
  desc "Erase a person's permission data (assignments, cache, audit-log names) for a GDPR Article 17 request. " \
       'Ids and other event data stay. USER_ID= required; a dry run unless DRY_RUN=false (or 0, no); ' \
       'ACTOR= names who ran it, REASON= why.'
  task erasure: :environment do
    user_id = ENV.fetch('USER_ID', nil)
    dry_run = PermissionForge::RakeDryRun.dry_run?(ENV.fetch('DRY_RUN', nil), default: true)

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

    person = PermissionForge::RakeOutput.person(user)
    if dry_run
      PermissionForge::RakeOutput.report("Dry run — would erase for #{person}:", result)
      puts '  (plus the name labels on the events the erasure itself writes)'
      puts "\nRun with DRY_RUN=false to execute."
    else
      PermissionForge::RakeOutput.report("Erasure complete for #{person}:", result)
      puts '  Kept: audit event ids, ip, request id, reason and data; *_by_id columns; the user record itself.'
    end
  end
end
