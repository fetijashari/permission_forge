# frozen_string_literal: true

# The one scanner for static guards: tests that fail when a pattern appears
# in the gem's own code outside the one place it may live (a "one
# definition" rule, a forbidden call, a duplicated decision). Modelled on
# audit_integration/callback_bypass_guard_test.rb.
#
#   hits = StaticGuard.scan(globs: %w[app/**/*.rb app/**/*.erb lib/**/*.rb],
#                           needle: /\.to_sentence\b/,
#                           canonical: %w[lib/permission_forge/admin/list_sentence.rb],
#                           allowlist: [['app/views/x.html.erb', /to_sentence/, 'why it may stay']])
#   assert_empty hits.map(&:to_s)
#   StaticGuard.assert_allowlist_current(self, globs: ..., needle: ..., allowlist: ...)
#
# - Comments are stripped before matching (Ruby `#` outside a string that
#   opens no interpolation; ERB `<%# … %>` tags), so a comment never hits.
# - `strings: :blank` (default) blanks string literals, so a needle inside a
#   string is no hit; `strings: :keep` matches them too (a key in a t() call,
#   a sent method name).
# - `canonical:` files may contain the needle (the one definition);
#   `allowlist:` entries are [file, line pattern, reason]; every entry must
#   still match a hit (assert_allowlist_current), so a stale entry fails.
# - A new guard is a new test file that calls this helper; never extend
#   another guard's lists to cover a new rule.
module StaticGuard
  ROOT = Pathname(File.expand_path('../..', __dir__))
  STRING_LITERAL = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/

  Hit = Struct.new(:file, :line_number, :line) do
    def to_s = "#{file}:#{line_number} #{line.strip}"
  end

  module_function

  # @return [Array<Hit>] every line matching `needle` outside `canonical`
  #   files and not covered by an `allowlist` entry
  def scan(globs:, needle:, canonical: [], allowlist: [], strings: :blank)
    all_hits(globs: globs, needle: needle, strings: strings).reject do |hit|
      canonical.include?(hit.file) || allowed?(hit, allowlist)
    end
  end

  # Every hit, canonical and allow-listed ones included.
  def all_hits(globs:, needle:, strings: :blank)
    files(globs).flat_map do |path|
      file = Pathname(path).relative_path_from(ROOT).to_s
      erb = file.end_with?('.erb')
      File.readlines(path).each_with_index.filter_map do |line, index|
        Hit.new(file, index + 1, line) if code_of(line, erb: erb, strings: strings).match?(needle)
      end
    end
  end

  def files(globs)
    Array(globs).flat_map { |glob| Dir[ROOT.join(glob).to_s] }.uniq.sort
  end

  # The line without its comment; string literals blanked unless `strings: :keep`.
  def code_of(line, erb: false, strings: :blank)
    line = line.gsub(/<%#.*?%>/, '') if erb
    bare = line.gsub(STRING_LITERAL) { |literal| literal[0] + (' ' * (literal.length - 2)) + literal[-1] }
    cut = erb ? nil : bare.index(/#(?!\{)/)
    code = strings == :keep ? line : bare
    cut ? code[0, cut] : code
  end

  def allowed?(hit, allowlist)
    allowlist.any? { |file, pattern, _reason| hit.file == file && hit.line.match?(pattern) }
  end

  # Fails the calling test when an allowlist entry has no reason or no
  # longer matches a hit (remove it), or a canonical file no longer contains
  # the needle (the one definition moved: update the guard). `scope` is
  # globs:, needle: and optionally strings:, as for .scan.
  def assert_allowlist_current(test, allowlist: [], canonical: [], **scope)
    hits = all_hits(**scope)
    allowlist.each { |entry| assert_entry_current(test, hits, *entry) }
    canonical.each do |file|
      test.assert hits.any? { |hit| hit.file == file }, "canonical file #{file} no longer contains #{scope[:needle].inspect}"
    end
  end

  def assert_entry_current(test, hits, file, pattern, reason)
    test.assert reason.to_s.strip.present?, "#{file}: give the allowlist entry a reason"
    test.assert hits.any? { |hit| hit.file == file && hit.line.match?(pattern) },
                "stale allowlist entry #{file} #{pattern.inspect}: remove it"
  end
end
