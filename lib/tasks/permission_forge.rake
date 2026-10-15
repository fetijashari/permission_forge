# frozen_string_literal: true

namespace :permission_forge do
  desc 'Report fields that match the personal-data patterns but are not masked, and matching model columns with no ResourceField'
  task audit_masks: :environment do
    report = PermissionForge::RakeAudit.reporting('permission_forge:audit_masks', counts: ->(r) { { findings: r.size } }) do
      PermissionForge::Services::GdprFieldAuditor.call
    end

    puts PermissionForge::Services::GdprFieldAuditor::TextReport.new(report)
    exit 1 if report.any?
  end
end

namespace :permission_forge do
  # Exits 1 when FAIL_ON is given and a finding of that severity or worse
  # exists (saying so on stderr, so FORMAT=json output stays parseable), and 2
  # when FAIL_ON names no severity (before the review runs).
  # It changes no permission data; every run is recorded (report.generated)
  # when the audit log is on.
  desc 'Security review of the PermissionForge setup: changes no permission data, records the run in the audit log. ' \
       'FORMAT=json, FAIL_ON=critical|high|medium|low|info'
  task audit: :environment do
    audit = PermissionForge::Services::SecurityAudit
    given = ENV.fetch('FAIL_ON', nil).presence
    fail_on = given && audit.severity_named(given)
    if given && fail_on.nil?
      warn "FAIL_ON must be one of #{audit::SEVERITIES.join(', ')} (got #{given.inspect}). " \
           'Usage: rake permission_forge:audit FAIL_ON=high'
      exit 2
    end

    report = PermissionForge::RakeAudit.reporting('permission_forge:audit', counts: :counts.to_proc) { audit.call }

    if ENV['FORMAT'] == 'json'
      puts JSON.pretty_generate(report.to_h)
    else
      puts PermissionForge::Services::SecurityAuditChecks::TextReport.new(report)
    end

    failing = fail_on ? report.at_least(fail_on).size : 0
    if failing.positive?
      warn "Failing: #{failing} finding(s) at or above #{fail_on} (FAIL_ON=#{given})."
      exit 1
    end
  end
end
