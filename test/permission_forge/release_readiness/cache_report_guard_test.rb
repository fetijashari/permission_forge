# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'
require_relative '../../support/measured_calls'

module PermissionForge
  module ReleaseReadiness
    # G3b. A service, rake task or controller that invalidates, clears or
    # removes cached permissions measures it through Cache::Report (one
    # Cache::Outcome: confirmed?, process-local?, unconfirmed) — never by
    # asking Cache::Failure, HolderInvalidation, VariantRemoval or the store
    # itself and composing the answer by hand (that is how three operations
    # came to report "process-local" three different ways).
    #
    # Placed per method (MeasuredCalls, R2 review P1-5): each such call sits
    # inside a measuring block (`Cache::Report.of { }`, `.measure { }`,
    # `cache_outcome { }`) or in a method every caller of which in its file
    # does — a file that mentions Cache::Report once no longer exempts its
    # other methods. A call the scan cannot place is allow-listed with a
    # reason, and every allow-list entry must still match.
    class CacheReportGuardTest < ActiveSupport::TestCase
      GLOBS = %w[lib/permission_forge/services/**/*.rb lib/tasks/**/*.rake app/controllers/**/*.rb
                 lib/permission_forge/admin/**/*.rb].freeze
      NEEDLE = /Cache::Failure\.(none\?|collect\b)|\b(invalidate|regenerate)_permissions\b|HolderInvalidation\.call|
                VariantRemoval\.call|\bcache(_store)?\.process_local\?|
                \bcache\.(clear|expunge|expunge_many|delete|delete_many|delete_matched)\b/x
      REPORTING = /\bCache::Report\b/
      ALLOWLIST = [
        ['lib/permission_forge/services/security_audit/config_check.rb', /cache_store\.process_local\?/,
         'a finding about the configured store, not a measurement of an invalidation: it asks the one definition']
      ].freeze
      FIXTURE = 'test/permission_forge/release_readiness/fixtures/invalidates_without_report.rb'
      MEASURING_FIXTURE = 'test/permission_forge/release_readiness/fixtures/measures_one_method.rb'

      def self.files_reporting(globs = GLOBS)
        StaticGuard.all_hits(globs: globs, needle: REPORTING).map(&:file).uniq
      end

      def self.hits(globs = GLOBS, allowlist: ALLOWLIST)
        MeasuredCalls.unmeasured(globs: globs, needle: NEEDLE, allowlist: allowlist)
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

      # The reviewer's fixture: a method of a file that does measure elsewhere.
      test 'negative fixture: an unmeasured method in a file that measures elsewhere is a hit' do
        hits = self.class.hits([MEASURING_FIXTURE], allowlist: [])

        assert_equal ['unmeasured_probe'], hits.map { |hit| hit.line[/def (?:self\.)?(\w+)/, 1] }, hits.map(&:to_s).inspect
        assert_includes self.class.files_reporting([MEASURING_FIXTURE]), MEASURING_FIXTURE
      end

      test 'negative fixture: a file that invalidates without Cache::Report is a hit' do
        hits = self.class.hits([FIXTURE], allowlist: [])

        assert_equal 1, hits.size, hits.map(&:to_s).inspect
        assert_match(/invalidate_permissions/, hits.first.line)
        assert_not_includes StaticGuard.files(GLOBS), StaticGuard::ROOT.join(FIXTURE).to_s, 'the fixture is scanned only when named'
      end

      test 'the needle sees every way of touching the cache the guard is about' do
        %w[Cache::Failure.none? Cache::Failure.collect user.invalidate_permissions user.regenerate_permissions
           Cache::HolderInvalidation.call Cache::VariantRemoval.call PermissionForge.cache.process_local?
           configuration.cache_store.process_local? PermissionForge.cache.clear PermissionForge.cache.expunge
           cache.expunge_many cache.delete cache.delete_matched].each do |call|
          assert_match NEEDLE, "  #{call} do", call
        end
        assert_no_match NEEDLE, '  cache.read(key)'
      end
    end
  end
end
