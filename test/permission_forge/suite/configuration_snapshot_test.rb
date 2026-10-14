# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Suite
    # The suite's own isolation (test/support/configuration_snapshot.rb):
    # whatever one test does to the configuration, the next starts from the
    # suite's base — also when a teardown raises before the restore runs.
    class ConfigurationSnapshotTest < ActiveSupport::TestCase
      # Run by hand below, never by the suite (no test_ methods): its
      # teardown raises before the base teardown's restore.
      class RaisingTeardown < ActiveSupport::TestCase
        self.use_transactional_tests = false
        cattr_accessor :seen

        teardown { raise 'a teardown that raises' if name == 'probe_changes_and_raises' }

        def probe_changes_and_raises
          PermissionForge.configuration.cache_ttl = 1
          PermissionForge.configuration.custom_mask_strategies[:leak] = ->(value) { value }
          ActsAsTenant.test_tenant = nil
          pass
        end

        def probe_reads
          configuration = PermissionForge.configuration
          self.class.seen = [configuration.cache_ttl, configuration.custom_mask_strategies.keys, ActsAsTenant.test_tenant]
          pass
        end
      end

      test 'a teardown that raises leaks nothing into the next test' do
        first = RaisingTeardown.new('probe_changes_and_raises').run
        assert_match(/a teardown that raises/, first.failures.map(&:message).join)

        second = RaisingTeardown.new('probe_reads').run
        assert_predicate second, :passed?

        assert_equal [3600, [], DEFAULT_TEST_ACCOUNT], RaisingTeardown.seen
      end

      test 'a test that replaces or mutates the configuration hands the next one the same object, as it was' do
        base = PermissionForge.configuration
        base.admin_session_flags['x'] = 'y'
        PermissionForge.reset!
        ConfigurationSnapshot.restore!

        assert_same base, PermissionForge.configuration
        assert_empty PermissionForge.configuration.admin_session_flags
      end
    end
  end
end
