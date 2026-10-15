# frozen_string_literal: true

namespace :permission_forge do
  namespace :cache do
    # Upgrading from 0.13 or earlier: run it once the last process of the
    # previous release is gone (it also removes the previous key namespace).
    desc "Remove every user's cached permissions at once; each user rebuilds on their next request. " \
         'ACTOR=, REASON= (After an upgrade from 0.13: run it once the old processes are gone.)'
    task clear: :environment do
      task_name = 'permission_forge:cache:clear'
      result = PermissionForge::RakeAudit.changing(task_name) { PermissionForge::Services::PermissionCacheClearer.call }
      PermissionForge::RakeAudit.log(task_name, result.map { |key, value| "#{key}=#{value.inspect}" }.join(' '))
      unconfirmed = result[:unconfirmed].positive? ? " (#{result[:unconfirmed]} not confirmed by the cache store)" : ''
      done = if result[:strategy] == :pattern
               'Removed every cached permission hash by key pattern (users not counted)'
             else
               "Invalidated the cached permissions of #{result[:users]} user visit(s) in #{result[:tenants]} tenant(s)"
             end
      puts "#{done}#{unconfirmed}. The cache is cold: each user rebuilds on their next request."
      if PermissionForge.cache.process_local?
        puts 'Only the cache store of this rake process was cleared: an in-memory store (cache_backend :memory, or ' \
             ':memory_store) lives in each process, so the web and job processes keep their entries until they ' \
             'restart or the entries expire (cache_ttl). Invalidate the users from inside those processes, or restart them.'
      end
    end
  end
end
