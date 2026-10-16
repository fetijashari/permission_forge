# frozen_string_literal: true

require 'test_helper'

module PermissionForge
  module ReleaseReadiness
    # Every CHANGELOG claim names the test that proves it. Each bullet of
    # `## [Unreleased]` and of every released section from 0.15.0 on carries
    # `<!-- pin: <path>#<test name> -->`; the path is a file of the
    # repository and the name a test defined in it:
    #
    # - a Ruby test file (test/**/*.rb, test/support parts included): the
    #   name of a `test '…'` block (or a `def test_…` method), written as the
    #   block names it or as the method name Minitest gives it. A name built
    #   in a loop (`test "#{verb} #{path} answers …"`) matches when the pin
    #   fills every interpolation; a pin that starts with `~` names a stable
    #   substring of a test name instead, for a name nothing fills statically;
    # - under `### Documentation` only, a Markdown file and one of its
    #   heading anchors (GitHub's slugs), as an alternative to a test.
    #
    # A pin to a renamed or deleted test fails here, so the claims of the
    # released sections stay tied to code that runs. The sections keep Keep a
    # Changelog's headings in one order, and every Changed bullet ends with
    # its opt-out (`**Opt out:** …`, or `**No opt-out:** <why>`).
    class ChangelogPinsTest < ActiveSupport::TestCase
      ROOT = Pathname(File.expand_path('../../..', __dir__))
      CHANGELOG = ROOT.join('CHANGELOG.md')
      FIRST_PINNED = Gem::Version.new('0.15.0')
      HEADINGS = %w[Added Changed Deprecated Removed Fixed Security Documentation].freeze
      PIN = /<!--\s*pin:\s*(?<path>[^#\s]+)#(?<name>.+?)\s*-->/
      TEST_LITERAL = /^\s*test\s*\(?\s*(?<quote>['"])(?<name>(?:\\.|(?!\k<quote>).)*)\k<quote>/
      TEST_METHOD = /^\s*def\s+(?<name>test_\w+)/

      # Bullets allowed without a pin: { 'start of the bullet' => 'why no test can prove it' }.
      UNPINNED = {}.freeze

      Bullet = Struct.new(:section, :heading, :text, :line) do
        def pins = text.to_enum(:scan, PIN).map { Regexp.last_match }
        def title = text[/\A-\s*(.{0,90})/, 1].to_s.gsub(/\s+/, ' ')
        def where = "CHANGELOG.md:#{line} [#{section}] ### #{heading}: #{title}"
      end

      # [section name, heading, bullet] for every bullet of the pinned sections.
      def self.bullets(text = CHANGELOG.read)
        found = []
        section = heading = nil
        current = nil
        text.each_line.with_index(1) do |raw, number|
          line = raw.chomp
          if (match = line.match(/\A## \[(?<name>[^\]]+)\]/))
            section = pinned_section?(match[:name]) ? match[:name] : nil
            heading = current = nil
          elsif section && (match = line.match(/\A### (?<name>.+?)\s*\z/))
            heading = match[:name]
            current = nil
          elsif section && line.start_with?('- ')
            current = Bullet.new(section, heading, +line, number)
            found << current
          elsif current && (line.start_with?(' ') || line.strip.start_with?('<!--'))
            current.text << "\n" << line
          elsif line.strip.empty? || !line.start_with?(' ')
            current = nil
          end
        end
        found
      end

      def self.pinned_section?(name)
        name == 'Unreleased' || Gem::Version.new(name) >= FIRST_PINNED
      rescue ArgumentError
        false
      end

      # [section name, [headings in order]] for the pinned sections.
      def self.headings(text = CHANGELOG.read)
        sections = []
        text.each_line do |line|
          if (match = line.match(/\A## \[(?<name>[^\]]+)\]/))
            sections << [match[:name], []] if pinned_section?(match[:name])
            sections << [nil, []] unless pinned_section?(match[:name])
          elsif (match = line.match(/\A### (?<name>.+?)\s*\z/)) && sections.last&.first
            sections.last.last << match[:name]
          end
        end
        sections.select(&:first)
      end

      # The test names a file defines: literals, method names, and a Regexp
      # for each literal built with interpolation.
      def self.test_names(path)
        @test_names ||= {}
        @test_names[path] ||= begin
          source = ROOT.join(path).read
          literals = source.to_enum(:scan, TEST_LITERAL).map { Regexp.last_match[:name] }
          methods = source.to_enum(:scan, TEST_METHOD).map { Regexp.last_match[:name] }
          { literals: literals, methods: methods }
        end
      end

      def self.method_name(name) = "test_#{name.gsub(/\s+/, '_')}"

      def self.interpolated(literal)
        parts = literal.split(/\#\{[^}]*\}/, -1).map { |part| Regexp.escape(part.gsub(/\\(.)/, '\1')) }
        /\A#{parts.join('.+')}\z/m
      end

      def self.test_defined?(path, name)
        names = test_names(path)
        if name.start_with?('~')
          needle = name.delete_prefix('~')
          return names[:literals].any? { |literal| literal.include?(needle) }
        end
        normalized = name.delete_prefix('test ').delete_prefix('test_')
        names[:literals].any? do |literal|
          [name, normalized].include?(literal) ||
            [name, method_name(normalized)].include?(method_name(literal)) ||
            (literal.include?('#{') && interpolated(literal).match?(normalized))
        end || names[:methods].any? { |method| [name, method_name(normalized)].include?(method) }
      end

      def self.anchors(path)
        @anchors ||= {}
        @anchors[path] ||= begin
          counts = Hash.new(0)
          fenced = false
          ROOT.join(path).read.each_line.filter_map do |line|
            fenced = !fenced if line.start_with?('```')
            next if fenced || !line.match?(/\A\#{1,6}\s/)

            slug = line.sub(/\A#+\s*/, '').strip.downcase.gsub(/[^\p{Word}\- ]/, '').tr(' ', '-')
            seen = counts[slug]
            counts[slug] += 1
            seen.zero? ? slug : "#{slug}-#{seen}"
          end
        end
      end

      # Why `pin` does not hold for `bullet`, or nil.
      def self.pin_problem(bullet, pin)
        path = pin[:path]
        name = pin[:name].strip
        return "#{path} does not exist" unless ROOT.join(path).file?
        return "#{path}: no test name after #" if name.empty?

        if path.end_with?('.md')
          return "#{path}: a document is a pin under ### Documentation only" unless bullet.heading == 'Documentation'
          return "#{path} has no heading ##{name}" unless anchors(path).include?(name)

          return nil
        end
        return "#{path} is not a Ruby test file" unless path.start_with?('test/') && path.end_with?('.rb')

        "#{path} defines no test named #{name.inspect}" unless test_defined?(path, name)
      end

      def self.problems(text = CHANGELOG.read)
        bullets(text).flat_map do |bullet|
          next [] if UNPINNED.keys.any? { |start| bullet.text.delete_prefix('- ').start_with?(start) }

          pins = bullet.pins
          next ["#{bullet.where}: no <!-- pin: test/…_test.rb#test name --> comment"] if pins.empty?

          pins.filter_map { |pin| (problem = pin_problem(bullet, pin)) && "#{bullet.where}: #{problem}" }
        end
      end

      test 'every bullet of Unreleased and of the sections from 0.15.0 on pins a test that exists' do
        assert_operator self.class.bullets.size, :>, 0, 'no bullet found: did the section headings change?'
        problems = self.class.problems
        assert_empty problems, "#{problems.size} CHANGELOG bullet(s) without a valid pin:\n#{problems.join("\n")}"
      end

      test 'the released section of this version exists, under an empty or pinned Unreleased' do
        names = self.class.headings.map(&:first)
        assert_includes names, 'Unreleased'
        assert_includes names, VERSION, "CHANGELOG.md has no ## [#{VERSION}] section"
      end

      test 'each pinned section uses Keep a Changelog headings, once each, in order' do
        self.class.headings.each do |name, headings|
          assert_empty headings - HEADINGS, "## [#{name}] has headings outside #{HEADINGS.join(', ')}"
          assert_equal headings.uniq, headings, "## [#{name}] repeats a heading"
          assert_equal HEADINGS & headings, headings, "## [#{name}] orders its headings differently from #{HEADINGS.join(', ')}"
        end
      end

      test 'every Changed bullet ends with its opt-out' do
        missing = self.class.bullets.select { |bullet| bullet.heading == 'Changed' }.reject do |bullet|
          body = bullet.text.gsub(PIN, '')
          body.include?('**No opt-out:**') || (body.include?('**Opt out:**') && !body.match?(/\*\*Opt out:\*\*\s*none\b/i))
        end
        assert_empty missing.map(&:where),
                     'a Changed bullet says **Opt out:** <how> or **No opt-out:** <why> ("Opt out: none" is a No opt-out)'
      end

      # The guard bites: a bullet without a pin, a pin to a missing test, a
      # document pinned outside Documentation, a loop-built name filled in.
      test 'the guard reports what it should, on a fixture' do
        fixture = <<~MARKDOWN
          ## [Unreleased]

          ### Added

          - Pinned to a real test. <!-- pin: test/permission_forge/release_readiness/changelog_pins_test.rb#every Changed bullet ends with its opt-out -->
          - Pinned by its method name.
            <!-- pin: test/permission_forge/release_readiness/changelog_pins_test.rb#test_every_Changed_bullet_ends_with_its_opt-out -->
          - Pinned by a substring. <!-- pin: test/permission_forge/release_readiness/changelog_pins_test.rb#~reports what it should -->
          - No pin at all.
          - A test that is not there. <!-- pin: test/permission_forge/release_readiness/changelog_pins_test.rb#no such test -->
          - A document outside Documentation. <!-- pin: docs/configuration.md#presets -->

          ### Documentation

          - A heading that exists. <!-- pin: docs/configuration.md#presets -->
          - A heading that does not. <!-- pin: docs/configuration.md#no-such-heading -->

          ## [0.14.1] - 2026-10-14

          ### Fixed

          - Older sections are not pinned.
        MARKDOWN
        problems = self.class.problems(fixture)

        assert_equal 4, problems.size, problems.join("\n")
        assert_match(/No pin at all.*no <!-- pin/, problems[0])
        assert_match(/defines no test named "no such test"/, problems[1])
        assert_match(/a document is a pin under ### Documentation only/, problems[2])
        assert_match(/has no heading #no-such-heading/, problems[3])
      end

      test 'a name built in a loop matches when the pin fills it' do
        literal = '#{verb} #{path} answers the schema'
        assert_match self.class.interpolated(literal), 'GET /api/stats answers the schema'
        refute_match self.class.interpolated(literal), 'GET /api/stats answers something else'
      end
    end
  end
end
