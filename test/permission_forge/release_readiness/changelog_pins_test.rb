# frozen_string_literal: true

require 'test_helper'
require 'open3'
require 'tmpdir'

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
      STRING = /'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"/
      # `test 'name'`, and the canary's `canary_test :key, 'name'`; the name may follow on the next line and be
      # several literals joined with a backslash.
      TEST_LITERAL = /^[ \t]*(?:test|canary_test\s+:\w+\s*,)\s*\(?\s*(?<name>(?:#{STRING})(?:\s*\\\s*\n\s*(?:#{STRING}))*)/
      TEST_METHOD = /^\s*def\s+(?<name>test_\w+)/

      # Bullets allowed without a pin: { 'start of the bullet' => 'why no test can prove it' }.
      UNPINNED = {
        "**On a phone, long content ran past the card's edge**" =>
          'measured only by test/browser/layout_probe.js (the browser CI job), a script with no named tests'
      }.freeze

      # Pins to a test another branch of this release writes: { 'path#name' => 'why it is not here yet' }.
      # An entry is removed once the test exists (the guard then checks it like any other pin).
      PENDING_PINS = {}.freeze

      SECTION = /\A## \[(?<name>[^\]]+)\]/
      HEADING = /\A### (?<name>.+?)\s*\z/

      Bullet = Struct.new(:section, :heading, :text, :line) do
        def pins = text.to_enum(:scan, PIN).map { Regexp.last_match }
        def title = text[/\A-\s*(.{0,90})/, 1].to_s.gsub(/\s+/, ' ')
        def where = "CHANGELOG.md:#{line} [#{section}] ### #{heading}: #{title}"
        def documentation? = heading == 'Documentation'
        def unpinned? = UNPINNED.keys.any? { |start| text.delete_prefix('- ').start_with?(start) }
      end

      # Walks the CHANGELOG once: the bullets and the headings of the pinned sections.
      class Walk
        attr_reader :bullets, :headings

        def initialize(text)
          @bullets = []
          @headings = []
          text.each_line.with_index(1) { |raw, number| feed(raw.chomp, number) }
        end

        private

        def feed(line, number)
          if (match = line.match(SECTION)) then open_section(match[:name])
          elsif @section && (match = line.match(HEADING)) then open_heading(match[:name])
          elsif @section && line.start_with?('- ') then open_bullet(line, number)
          else continue_bullet(line)
          end
        end

        def open_section(name)
          @section = ChangelogPinsTest.pinned_section?(name) ? name : nil
          @headings << [name, []] if @section
          @heading = @current = nil
        end

        def open_heading(name)
          @heading = name
          @headings.last.last << name
          @current = nil
        end

        def open_bullet(line, number)
          @current = Bullet.new(@section, @heading, +line, number)
          @bullets << @current
        end

        def continue_bullet(line)
          return @current = nil unless @current && (line.start_with?(' ') || line.strip.start_with?('<!--'))

          @current.text << "\n" << line
        end
      end

      # Every bullet of the pinned sections.
      def self.bullets(text = CHANGELOG.read) = Walk.new(text).bullets

      # [section name, [headings in order]] for the pinned sections.
      def self.headings(text = CHANGELOG.read) = Walk.new(text).headings

      def self.pinned_section?(name)
        name == 'Unreleased' || Gem::Version.new(name) >= FIRST_PINNED
      rescue ArgumentError
        false
      end

      # The test names a file defines: its `test` literals and its `test_` methods.
      def self.test_names(path)
        @test_names ||= {}
        @test_names[path] ||= begin
          source = ROOT.join(path).read
          { literals: source.to_enum(:scan, TEST_LITERAL).map { unquote(Regexp.last_match[:name]) },
            methods: source.to_enum(:scan, TEST_METHOD).map { Regexp.last_match[:name].delete_prefix('test_') } }
        end
      end

      # The name one or more joined string literals spell.
      def self.unquote(literals)
        literals.scan(STRING).map { |quoted| quoted[1...-1].gsub(/\\(['"\\])/, '\\1') }.join
      end

      # A test name as Minitest's method name spells it, without the `test_` prefix.
      def self.canonical(name) = name.sub(/\Atest[ _]/, '').gsub(/\s+/, '_')

      def self.interpolated(literal)
        parts = literal.split(/\#\{[^}]*\}/, -1).map { |part| Regexp.escape(canonical(part.gsub(/\\(.)/, '\\1'))) }
        /\A#{parts.join('.+')}\z/m
      end

      def self.test_defined?(path, name)
        names = test_names(path)
        return names[:literals].any? { |literal| literal.include?(name.delete_prefix('~')) } if name.start_with?('~')

        wanted = canonical(name)
        names[:methods].include?(wanted) || names[:literals].any? { |literal| literal_matches?(literal, wanted) }
      end

      def self.literal_matches?(literal, wanted)
        canonical(literal) == wanted || (literal.include?('#{') && interpolated(literal).match?(wanted))
      end

      # GitHub's heading slugs of a Markdown file (headings inside a code fence do not count).
      def self.anchors(path)
        @anchors ||= {}
        @anchors[path] ||= begin
          counts = Hash.new(0)
          headings_outside_fences(ROOT.join(path).read).map do |slug|
            seen = counts[slug]
            counts[slug] += 1
            seen.zero? ? slug : "#{slug}-#{seen}"
          end
        end
      end

      def self.headings_outside_fences(text)
        fenced = false
        text.each_line.filter_map do |line|
          fenced = !fenced if line.start_with?('```')
          line.sub(/\A#+\s*/, '').strip.downcase.gsub(/[^\p{Word}\- ]/, '').tr(' ', '-') if !fenced && line.match?(/\A\#{1,6}\s/)
        end
      end

      def self.pending?(path, name)
        PENDING_PINS.key?("#{path}##{name}") && !(ROOT.join(path).file? && test_defined?(path, name))
      end

      # Why `pin` does not hold for `bullet`, or nil.
      def self.pin_problem(bullet, pin)
        path = pin[:path]
        name = pin[:name].strip
        return nil if pending?(path, name)
        return "#{path} does not exist" unless ROOT.join(path).file?
        return document_problem(bullet, path, name) if path.end_with?('.md')

        test_problem(path, name)
      end

      def self.document_problem(bullet, path, name)
        return "#{path}: a document is a pin under ### Documentation only" unless bullet.documentation?

        "#{path} has no heading ##{name}" unless anchors(path).include?(name)
      end

      def self.test_problem(path, name)
        return "#{path} is not a Ruby test file" unless path.start_with?('test/') && path.end_with?('.rb')
        return "#{path}: no test name after #" if name.empty?

        "#{path} defines no test named #{name.inspect}" unless test_defined?(path, name)
      end

      def self.problems(text = CHANGELOG.read)
        bullets(text).reject(&:unpinned?).flat_map do |bullet|
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

      test 'every PENDING_PINS entry is a pin of the CHANGELOG whose test is not written yet' do
        pins = self.class.bullets.flat_map(&:pins).map { |pin| "#{pin[:path]}##{pin[:name].strip}" }
        PENDING_PINS.each_key do |pin|
          assert_includes pins, pin, 'a pending pin no bullet carries: remove the entry'
          path, name = pin.split('#', 2)
          assert_not ROOT.join(path).file? && self.class.test_defined?(path, name),
                     "#{pin} exists now: remove it from PENDING_PINS"
        end
      end

      test 'the released section of this version exists, under an empty or pinned Unreleased' do
        names = self.class.headings.map(&:first)
        assert_includes names, 'Unreleased'
        assert_includes names, VERSION, "CHANGELOG.md has no ## [#{VERSION}] section"
      end

      # The release workflow publishes this section as the GitHub Release body
      # (.github/scripts/release_notes.sh, before the approval): the pins are
      # left out, and the body must fit GitHub's limit.
      test 'the release notes of this version come out of the script, without pins, and fit a GitHub Release' do
        script = ROOT.join('.github/scripts/release_notes.sh').to_s
        notes, errors, status = Open3.capture3('bash', script, VERSION, CHANGELOG.to_s)

        assert status.success?, errors
        assert_match(/^### /, notes)
        assert_no_match(/<!--\s*pin:/, notes)
      end

      # Over GitHub's limit the body comes out condensed (headings, each
      # bullet's bold lead, a link to the full section) instead of failing.
      test 'a section too long for a GitHub Release comes out condensed, with a link to the full section' do
        bullet = "- **A change worth a line.** #{'Detail ' * 40}\n  continued #{'more ' * 30}\n"
        Dir.mktmpdir do |dir|
          changelog = File.join(dir, 'CHANGELOG.md')
          File.write(changelog, "# Changelog\n\n## [9.9.9] - 2026-01-01\n\nRun the audit first.\n\n### Added\n\n#{bullet * 400}\n" \
                                "### Fixed\n\n- **Wrapped bold lead\n  across two lines.** text\n\n## [9.9.8] - 2025-01-01\n\n### Added\n\n- **Old.**\n")
          notes, errors, status = Open3.capture3('bash', ROOT.join('.github/scripts/release_notes.sh').to_s, '9.9.9', changelog)

          assert status.success?, errors
          assert_operator notes.bytesize, :<, 124_000
          assert_equal 400, notes.scan('- **A change worth a line.**').size
          assert_includes notes, '- **Wrapped bold lead across two lines.**'
          assert_includes notes, 'Run the audit first.'
          assert_no_match(/Detail|continued|Old\./, notes)
          assert_includes notes, 'https://github.com/fetijashari/permission_forge/blob/v9.9.9/CHANGELOG.md'
        end
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
        path = 'test/permission_forge/release_readiness/changelog_pins_test.rb'
        literal = '#{verb} #{path} answers the schema' # rubocop:disable Lint/InterpolationCheck
        assert_match self.class.interpolated(literal), self.class.canonical('GET /api/stats answers the schema')
        refute_match self.class.interpolated(literal), self.class.canonical('GET /api/stats answers something else')
        assert self.class.test_defined?(path, 'test a name built in a loop matches when the pin fills it')
        assert self.class.test_defined?(path, 'test_a_name_built_in_a_loop_matches_when_the_pin_fills_it')
      end
    end
  end
end
