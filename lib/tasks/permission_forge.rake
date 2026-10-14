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
  desc 'Read-only security review of the PermissionForge setup. FORMAT=json, FAIL_ON=critical|high|medium|low'
  task audit: :environment do
    report = PermissionForge::RakeAudit.reporting('permission_forge:audit', counts: :counts.to_proc) do
      PermissionForge::Services::SecurityAudit.call
    end

    if ENV['FORMAT'] == 'json'
      puts JSON.pretty_generate(report.to_h)
    else
      puts PermissionForge::Services::SecurityAuditChecks::TextReport.new(report)
    end

    fail_on = ENV.fetch('FAIL_ON', nil).presence
    exit 1 if fail_on && report.at_least(fail_on).any?
  end
end
