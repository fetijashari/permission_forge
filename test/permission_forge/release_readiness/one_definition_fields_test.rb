# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'
require_relative '../../support/one_definition/fields'

module PermissionForge
  module ReleaseReadiness
    # G4, the field-row part (plan-final.md §2 OD): every needle of
    # OneDefinition::FIELDS appears only in its canonical files or on an
    # allow-listed line; every allow-list entry and canonical file is current;
    # every needle bites (its fixture line is a hit). The table is
    # test/support/one_definition/fields.rb; the rules part has its own table
    # and loader (one_definition_guard_test.rb).
    class OneDefinitionFieldsTest < ActiveSupport::TestCase
      SCAN_KEYS = %i[globs needle canonical allowlist].freeze

      OneDefinition::FIELDS.each do |entry|
        scope = entry.slice(*SCAN_KEYS)

        test "#{entry[:name]} is defined once" do
          hits = StaticGuard.scan(**scope)
          assert_empty hits.map(&:to_s), "re-derived outside #{entry[:canonical].join(', ')}"
          StaticGuard.assert_allowlist_current(self, **scope)
        end

        test "#{entry[:name]}: the needle bites its fixture line" do
          with_fixture_file(entry[:fixture]) do |path|
            hits = StaticGuard.scan(globs: [path], needle: entry[:needle])
            assert_equal 1, hits.size, "#{entry[:needle].inspect} must hit #{entry[:fixture].inspect}"
          end
        end
      end

      private

      # A one-line Ruby file under the repo's tmp/ (StaticGuard reports paths
      # relative to the repo root), removed afterwards.
      def with_fixture_file(line)
        dir = StaticGuard::ROOT.join('tmp', 'one_definition_fixtures', Process.pid.to_s)
        FileUtils.mkdir_p(dir)
        path = dir.join("#{SecureRandom.hex(4)}.rb")
        File.write(path, "#{line}\n")
        yield path.to_s
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
