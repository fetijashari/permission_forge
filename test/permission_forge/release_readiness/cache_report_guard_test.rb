# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

module PermissionForge
  module ReleaseReadiness
    # G3b. A service, rake task or controller that invalidates, clears or
    # removes cached permissions measures it through Cache::Report (one
    # Cache::Outcome: confirmed?, process-local?, unconfirmed) — never by
    # asking Cache::Failure, HolderInvalidation, VariantRemoval or the store
    # itself and composing the answer by hand (that is how three operations
    # came to report "process-local" three different ways). A file with such
    # a call either goes through Cache::Report or is allow-listed with a
    # reason, and every allow-list entry must still match.
    class CacheReportGuardTest < ActiveSupport::TestCase
      GLOBS = %w[lib/permission_forge/services/**/*.rb lib/tasks/**/*.rake app/controllers/**/*.rb].freeze
      NEEDLE = /Cache::Failure\.(none\?|collect\b)|\binvalidate_permissions\b|HolderInvalidation\.call|VariantRemoval\.call|
                \bcache(_store)?\.process_local\?|PermissionForge\.cache\.(clear|expunge)\b/x
      REPORTING = /\bCache::Report\b/
      ALLOWLIST = [
        ['app/controllers/permission_forge/people_controller.rb', /invalidate_permissions/,
         'inside CacheConfirmation#cache_outcome, which is Cache::Report.of'],
        ['lib/permission_forge/services/security_audit/config_check.rb', /cache_store\.process_local\?/,
         'a finding about the configured store, not a measurement of an invalidation: it asks the one definition']
      ].freeze
      FIXTURE = 'test/permission_forge/release_readiness/fixtures/invalidates_without_report.rb'

      def self.files_reporting(globs = GLOBS)
        StaticGuard.all_hits(globs: globs, needle: REPORTING).map(&:file).uniq
      end

      def self.hits(globs = GLOBS, allowlist: ALLOWLIST)
        StaticGuard.scan(globs: globs, needle: NEEDLE, canonical: files_reporting(globs), allowlist: allowlist)
      end

      test 'every invalidation in a service, task or controller is measured by Cache::Report' do
        assert_empty self.class.hits.map(&:to_s)
      end

      test 'the allow-list is current and Cache::Report is used where the guard expects it' do
        StaticGuard.assert_allowlist_current(self, globs: GLOBS, needle: NEEDLE, allowlist: ALLOWLIST)
        %w[lib/permission_forge/services/permission_cache_clearer.rb lib/permission_forge/services/data_subject_erasure.rb
           lib/permission_forge/services/expired_assignment_cleaner.rb lib/permission_forge/services/consent_withdrawal_handler.rb
           lib/permission_forge/services/bulk_permission_set_assignment.rb
           app/controllers/concerns/permission_forge/cache_confirmation.rb].each do |file|
          assert_includes self.class.files_reporting, file, "#{file} no longer goes through Cache::Report"
        end
      end

      test 'negative fixture: a file that invalidates without Cache::Report is a hit' do
        hits = self.class.hits([FIXTURE], allowlist: [])

        assert_equal 1, hits.size, hits.map(&:to_s).inspect
        assert_match(/invalidate_permissions/, hits.first.line)
        assert_not_includes StaticGuard.files(GLOBS), StaticGuard::ROOT.join(FIXTURE).to_s, 'the fixture is scanned only when named'
      end

      test 'the needle sees every way of touching the cache the guard is about' do
        %w[Cache::Failure.none? Cache::Failure.collect user.invalidate_permissions Cache::HolderInvalidation.call
           Cache::VariantRemoval.call PermissionForge.cache.process_local? configuration.cache_store.process_local?
           PermissionForge.cache.clear PermissionForge.cache.expunge].each do |call|
          assert_match NEEDLE, "  #{call} do", call
        end
        assert_no_match NEEDLE, '  cache.read(key)'
      end
    end
  end
end
