# frozen_string_literal: true

namespace :permission_forge do
  namespace :rls do
    desc 'Generate and install Postgres RLS policies from the current rule state (drop + recreate)'
    task sync: :environment do
      results = PermissionForge::RLS.sync!
      results.each do |result|
        skipped = result[:skipped_rules].size
        suffix = skipped.positive? ? " (#{skipped} untranslatable rule(s) skipped — see log)" : ''
        puts "Synced RLS policies for #{result[:table]} (digest #{result[:digest][0, 12]}…)#{suffix}"
      end
      puts "#{results.size} table(s) synced."
    end

    desc 'Report per-table RLS policy drift (rules changed since last sync / policies missing)'
    task status: :environment do
      reports = PermissionForge::RLS.drift_report
      reports.each do |report|
        state = if report[:in_sync]
                  'in sync'
                elsif report[:stored].nil?
                  'NOT INSTALLED'
                else
                  'STALE — run permission_forge:rls:sync'
                end
        puts "#{report[:table]}: #{state}"
      end
      exit 1 unless reports.all? { |report| report[:in_sync] }
    end

    desc 'Remove PermissionForge RLS policies and disable row-level security on protected tables'
    task remove: :environment do
      PermissionForge::RLS.remove!
      puts 'RLS policies removed and row-level security disabled on protected tables.'
    end
  end
end
