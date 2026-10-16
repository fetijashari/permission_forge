# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module Docs
    # Field test round 7 (A#131): the upgrade notes left a 0.14 and a 0.13
    # reader unsure — whether to run `permission_forge:upgrade` at all, and a
    # 0.13 path given three ways (through 0.14 first; or 0.15 plus
    # cache:clear; or cache:clear alone). "Upgrading to 0.15" opens with a
    # three-step checklist, the 0.13 path is stated once (its "From 0.13"
    # section) and everything else links to it, and the CHANGELOG's 0.15.0
    # intro links the checklist and names the Changed entries that need
    # action. references_test checks every anchor these links name.
    class UpgradeNotesTest < ActiveSupport::TestCase
      ROOT = Pathname.new(File.expand_path('../../..', __dir__))
      GUIDE = 'docs/migration-guide.md'
      FROM_013 = 'migration-guide.md#from-013'

      def read(file) = File.read(ROOT.join(file))

      # The text under the heading line that starts with `heading`, up to the
      # next heading of its level or above.
      def section(text, heading)
        level = heading[/\A#+/].size
        start = text.index(/^#{Regexp.escape(heading)}.*\n/)
        assert start, "no #{heading.inspect}"
        rest = text[(start + Regexp.last_match(0).size)..]
        stop = rest.index(/^\#{1,#{level}} /) || rest.size
        rest[0...stop]
      end

      test 'Upgrading to 0.15 opens with the three-step checklist' do
        body = section(read(GUIDE), '## Upgrading to 0.15')
        steps = body.lstrip.lines.take_while { |line| line.match?(/\A\d\.|\A {3}/) }.join
        items = steps.scan(/^\d\. (.*)$/).flatten

        assert_equal 3, items.size, "the guide opens with the checklist:\n#{body.lines.first(8).join}"
        assert_match(/no generator/i, items[0])
        assert_includes items[0], 'permission_forge:upgrade'
        assert_includes items[0], 'older than 0.13'
        assert_includes items[1], 'permission_forge:audit'
        assert_includes items[2], 'permission_forge:rls:sync'
      end

      test 'the 0.13 path is stated once, in From 0.13, and the rest link to it' do
        guide = read(GUIDE)
        from = section(guide, '### From 0.13')
        assert_includes from, 'permission_forge:cache:clear'

        others = { 'README.md' => read('README.md'), GUIDE => guide.sub(from, ''),
                   'CHANGELOG.md' => section(read('CHANGELOG.md'), '## [0.15.0]') }
        others.each do |file, text|
          assert_no_match(/upgrades? (?:to|through) 0\.14 first|upgrades through 0\.14/i, text, "#{file} states another 0.13 path")
        end
        assert_includes read('README.md'), FROM_013, 'README links to the 0.13 path'
        assert_includes others['CHANGELOG.md'], FROM_013, 'the Removed entry links to it'
      end

      # Review of the round-7 fixes (P2-3): "From 0.13" told of the gap one
      # way only. Since 0.15 no invalidation removes 0.13's bare keys
      # (Cache::UserKeys::PREVIOUS_ENTRY_NAMESPACES is empty), so a
      # revocation made by a 0.15 process leaves the 0.13 processes serving
      # the revoked access until cache_ttl. Both directions are stated, with
      # the two paths: through 0.14 (which still removes the bare keys), or
      # straight to 0.15 accepting up to cache_ttl of stale grants.
      test 'From 0.13 states the cache gap in both directions and the two paths' do
        assert_empty Cache::UserKeys::PREVIOUS_ENTRY_NAMESPACES, 'the reverse gap exists: 0.15 removes no bare key'
        from = section(read(GUIDE), '### From 0.13').squish

        assert_match(/made by a 0\.13 process.*does not reach.*`pf:v2:`/, from, '0.13 → 0.15')
        assert_match(/made by a 0\.15 process.*`PREVIOUS_ENTRY_NAMESPACES`.*0\.13 process.*revoked.*`cache_ttl`/, from, '0.15 → 0.13')
        assert_match(/\*\*Through 0\.14\*\*.*still removes 0\.13's bare keys/, from, 'the path with no reverse window')
        assert_match(/\*\*Straight to 0\.15\*\*.*`cache_ttl` of stale grants.*permission_forge:cache:clear.*last 0\.13 process is gone/,
                     from, 'the direct path and what it accepts')
        assert_includes read('README.md')[/^From 0\.13:.*$/], 'revocation', 'the README pointer names the gap'
      end

      test 'the CHANGELOG intro links the checklist and names the Changed entries that need action' do
        intro = section(read('CHANGELOG.md'), '## [0.15.0]').split('### Added').first

        assert_includes intro, 'migration-guide.md#upgrading-to-015'
        changed = section(read('CHANGELOG.md'), '## [0.15.0]')[/### Changed\n(.*?)\n### /m, 1]
        named = intro.scan(/\*\*([^*]+)\*\*/).flatten.map(&:squish)
        assert_operator named.size, :>=, 3, 'the intro names the entries that need action'
        titles = changed.scan(/^- \*\*([^*]+)\*\*/).flatten.map(&:squish)
        named.each { |title| assert_includes titles, title, "#{title.inspect} is the title of a Changed entry" }
      end
    end
  end
end
