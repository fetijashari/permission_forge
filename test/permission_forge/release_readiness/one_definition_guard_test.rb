# frozen_string_literal: true

require 'test_helper'
require_relative '../../support/static_guard'

Dir[File.expand_path('../../support/one_definition/*.rb', __dir__)].each { |file| require file }

module PermissionForge
  module ReleaseReadiness
    # G4: a decision has one definition (CLAUDE.md "Rules"); every other path
    # calls it. The needles live in test/support/one_definition/*.rb (one
    # file per work package: OneDefinition::RULES, ::FIELDS, ...); a hit
    # outside the rule's canonical files and allow-list fails, and so does a
    # stale allow-list entry or a canonical file that lost the needle.
    class OneDefinitionGuardTest < ActiveSupport::TestCase
      RULES = OneDefinition.constants.map { |name| OneDefinition.const_get(name) }
                           .select { |value| value.is_a?(Array) && value.all?(Hash) }.flatten.freeze

      test 'the needle tables are loaded' do
        assert_operator RULES.size, :>=, OneDefinition::RULES.size
        assert RULES.all? { |rule| rule.key?(:name) && rule.key?(:needle) }, 'every rule names itself and its needle'
      end

      RULES.each do |rule|
        test "one definition: #{rule[:name]}" do
          hits = StaticGuard.scan(globs: OneDefinition::GLOBS, needle: rule[:needle], canonical: rule.fetch(:canonical, []),
                                  allowlist: rule.fetch(:allowlist, []))

          assert_empty hits.map(&:to_s), "#{rule[:name]}: re-derived outside #{rule[:canonical].inspect}"
          StaticGuard.assert_allowlist_current(self, globs: OneDefinition::GLOBS, needle: rule[:needle],
                                                     canonical: rule.fetch(:canonical, []), allowlist: rule.fetch(:allowlist, []))
        end
      end

      # The guard bites: a re-derived line is a hit, a comment or a string is not.
      test 'a re-derivation is a hit (negative fixture)' do
        OneDefinition::RULES.each do |rule|
          canonical = rule.fetch(:canonical, []).first
          next unless canonical

          line = StaticGuard.all_hits(globs: [canonical], needle: rule[:needle]).first&.line
          assert line, "#{rule[:name]}: the canonical file carries the needle"
          assert_match rule[:needle], StaticGuard.code_of(line), rule[:name]
          assert_no_match rule[:needle], StaticGuard.code_of("# #{line.strip}"), "#{rule[:name]}: a comment is no hit"
        end
      end
    end
  end
end
