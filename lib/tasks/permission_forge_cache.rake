# frozen_string_literal: true

namespace :permission_forge do
  namespace :cache do
    # Upgrading from 0.13 or earlier: run it once the last process of the
    # previous release is gone (it also removes the previous key namespace).
    # What it prints is the result the cache.cleared event records
    # (RakeOutput), the cache outcome included: on an in-memory store only
    # this process's store is cleared, and the output says so.
    desc "Remove every user's cached permissions at once; each user rebuilds on their next request. " \
         'ACTOR=, REASON= (After an upgrade from 0.13: run it once the old processes are gone.)'
    task clear: :environment do
      task_name = 'permission_forge:cache:clear'
      result = PermissionForge::RakeAudit.changing(task_name) { PermissionForge::Services::PermissionCacheClearer.call }
      PermissionForge::RakeAudit.log(task_name, result.map { |key, value| "#{key}=#{value.inspect}" }.join(' '))
      # what it means for the users is the outcome's "Cache scope" line (a shared store: every user rebuilds on their
      # next request; a per-process store: this process's only), never a second claim here
      done = if result[:strategy] == :pattern
               'Removed every cached permission hash by key pattern:'
             else
               'Invalidated the cached permissions of every user:'
             end
      PermissionForge::RakeOutput.report(done, result)
    end
  end
end
