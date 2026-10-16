# frozen_string_literal: true

require 'pathname'
require 'ripper'

# The one parser of the fenced code blocks in README.md and docs/*.md, and
# the rules every block follows (docs/doc_blocks_test.rb is the meta test;
# docs/doc_samples_test.rb runs the programs it builds).
#
# A block's info string names its language and what the block is:
#
#   ```ruby run                 a console sample: executed in order, one
#                               binding per document, in the docs app; a
#                               `# => literal` comment is asserted
#   ```ruby file=app/x.rb       written into the docs app at that path
#                               before the run blocks that follow it (also
#                               erb, yaml, ...)
#   ```ruby fragment            cannot run (an excerpt, pseudo-code, a
#                               template with placeholders); same for bash
#   ```bash run                 shell lines run in the app
#
# Every ruby, erb and bash block must say which one it is (MARKED_LANGS);
# other languages (json, yaml, sql, mermaid, text) may carry `file=`.
#
#   DocBlocks.all                      every block of every document
#   DocBlocks.documents                [Document(file, blocks)] with #program
#   DocBlocks.problems(blocks)         what the meta test reports
#   DocBlocks.parse(text, file: 'x.md') one document's blocks (fixtures)
module DocBlocks
  ROOT = Pathname(File.expand_path('../..', __dir__))

  MARKED_LANGS = %w[ruby erb bash].freeze
  MARKERS = %w[run fragment].freeze
  # Spell the language one way: the aliases are refused.
  LANG_ALIASES = { 'rb' => 'ruby', 'sh' => 'bash', 'shell' => 'bash', 'console' => 'bash', 'zsh' => 'bash',
                   'html+erb' => 'erb', 'yml' => 'yaml' }.freeze
  # A `file=` path ends the way its language does.
  FILE_EXTENSIONS = { 'ruby' => %w[.rb .rake .jbuilder Gemfile], 'erb' => %w[.erb], 'yaml' => %w[.yml .yaml],
                      'bash' => %w[.sh], 'css' => %w[.css], 'html' => %w[.html], 'javascript' => %w[.js],
                      'json' => %w[.json], 'sql' => %w[.sql] }.freeze

  # The denial handler the rounds rewrote four times. Every ruby block that
  # rescues a denial error is held to the version that works in a Rails 8
  # Turbo app; the four earlier versions fail.
  HANDLER = /rescue_from\b.*(?:ActionNotAuthorizedError|NotAuthorizedError)/
  HANDLER_RULES = [
    [/redirect_back\b/, 'redirect_back loops when the refused page is the root (R2 #68)'],
    [/format\.html\s*\{\s*head :forbidden/, 'head :forbidden for HTML leaves the sign-in form on screen (R3 #66)'],
    [/\brender\s+file:/, 'rendering public/403.html gives a static page Turbo reloads into (R4 #74)'],
    [->(body) { body.match?(/redirect_to\s+(?:main_app\.)?new_session_path/) && !body.match?(/request\.path\s*!=\s*new_session_path/) },
     'a redirect to the sign-in page must skip the sign-in page itself (request.path != new_session_path) (R5 #65)']
  ].freeze

  SCALAR = /true|false|nil|-?\d+(?:\.\d+)?|:[A-Za-z_]\w*[?!]?|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
  PAIR = /(?:#{SCALAR}\s*=>\s*#{SCALAR}|[A-Za-z_]\w*:\s*#{SCALAR}|"(?:[^"\\]|\\.)*":\s*#{SCALAR})/
  # What a `# =>` comment may claim and be checked for: a scalar literal, or
  # an Array / Hash of scalars. Ids, uuids, times and records are not.
  LITERAL = /\A(?:#{SCALAR}|\[\s*(?:#{SCALAR}(?:\s*,\s*#{SCALAR})*)?\s*\]|\{\s*(?:#{PAIR}(?:\s*,\s*#{PAIR})*)?\s*\})\z/

  FENCE = /\A(?<indent>\s*)(?<fence>`{3,}|~{3,})(?<info>[^`]*)\z/
  HEADING = /\A\#{1,6}\s/

  # A `# => claim` comment inside a run block. `assert?` is true only for a
  # LITERAL claim; the others are documentation.
  Expectation = Struct.new(:line, :source, :claim, keyword_init: true) do
    def assert? = DocBlocks.literal?(claim)
  end

  # One fenced block. `line` is the line of the opening fence (where the
  # marker is written); `body` the lines between the fences.
  Block = Struct.new(:file, :line, :lang, :tokens, :body, :heading, keyword_init: true) do
    def location = "#{file}:#{line}"
    def marker = tokens.first&.sub(/=.*/, '')
    def run? = marker == 'run'
    def fragment? = marker == 'fragment'
    def file? = marker == 'file'
    def marked? = run? || fragment? || file?
    def must_mark? = MARKED_LANGS.include?(LANG_ALIASES.fetch(lang, lang))
    def path = tokens.first.to_s[/\Afile=(.+)\z/, 1]
    def ruby? = lang == 'ruby'
    def info = [lang, *tokens].join(' ')

    def expectations
      body.lines.each_with_index.filter_map do |text, offset|
        source, claim = text.chomp.split(/\s*#\s*=>\s*/, 2)
        Expectation.new(line: line + 1 + offset, source: source.to_s.strip, claim: claim.strip) if claim
      end
    end
  end

  # One document and, in order, what runs: its `file=` and `run` blocks.
  Document = Struct.new(:file, :blocks, keyword_init: true) do
    def program = blocks.select { |block| block.run? || block.file? }
  end

  module_function

  def files(root: ROOT)
    ['README.md', *Dir[root.join('docs/*.md').to_s].map { |path| Pathname(path).relative_path_from(root).to_s }.sort]
  end

  def all(root: ROOT)
    files(root: root).flat_map { |file| parse(File.read(root.join(file)), file: file) }
  end

  def documents(root: ROOT)
    all(root: root).group_by(&:file).map { |file, blocks| Document.new(file: file, blocks: blocks) }
  end

  # A fence of N backticks (or tildes) closes on a line of at least N of the
  # same character and nothing else, so a ```ruby inside a ````markdown block
  # is content, not a block.
  def parse(text, file:)
    parser = Parser.new(file)
    text.lines.each_with_index { |raw, index| parser.feed(raw, index + 1) }
    parser.blocks
  end

  def closes?(line, open)
    stripped = line.strip
    stripped.start_with?(open[:fence]) && stripped.delete(open[:fence][0]).empty?
  end

  # Reads a document line by line: the heading in force, the open fence and
  # the blocks closed so far.
  class Parser
    attr_reader :blocks

    def initialize(file)
      @file = file
      @blocks = []
      @heading = nil
      @open = nil
    end

    def feed(raw, number)
      line = raw.chomp
      if @open
        DocBlocks.closes?(line, @open) ? close : @open[:body] << raw
      elsif (match = line.match(FENCE))
        @open = { line: number, fence: match[:fence], info: match[:info].strip, body: +'' }
      elsif line.match?(HEADING)
        @heading = line.strip
      end
    end

    private

    def close
      lang, *tokens = @open[:info].split(/\s+/)
      @blocks << Block.new(file: @file, line: @open[:line], lang: lang.to_s, tokens: tokens, body: @open[:body], heading: @heading)
      @open = nil
    end
  end

  def literal?(claim) = LITERAL.match?(claim.to_s.strip)

  # Everything the meta test reports, one message per problem.
  def problems(blocks)
    blocks.flat_map { |block| block_problems(block) } + duplicate_file_problems(blocks)
  end

  def block_problems(block)
    [alias_problem(block), *marker_problems(block), syntax_problem(block), *handler_problems(block)].compact
  end

  def alias_problem(block)
    "#{block.location}: spell the language `#{LANG_ALIASES[block.lang]}`, not `#{block.lang}`" if LANG_ALIASES.key?(block.lang)
  end

  def syntax_problem(block)
    return unless ruby_program?(block)

    error = syntax_error(block.body)
    "#{block.location}: a `#{block.marker}` ruby block must be valid Ruby (#{error})" if error
  end

  def marker_problems(block)
    return token_problems(block) unless block.tokens.empty?
    return [] unless block.must_mark?

    ["#{block.location}: ```#{block.lang} block has no marker: say `run`, `fragment` or `file=<path>`"]
  end

  def token_problems(block)
    tokens = block.tokens
    problems = []
    problems << "#{block.location}: `#{tokens.first}` is not a marker (run, fragment, file=<path>)" unless block.marked?
    problems << "#{block.location}: one marker per block, got `#{tokens.join(' ')}`" if tokens.size > 1
    problems.concat(path_problems(block)) if block.file?
    problems
  end

  def path_problems(block)
    path = block.path.to_s
    return ["#{block.location}: file= needs a path"] if path.empty?

    [location_problem(block, path), extension_problem(block, path)].compact
  end

  def location_problem(block, path)
    return unless path.start_with?('/') || path.split('/').include?('..')

    "#{block.location}: file=#{path} must be a path inside the app (relative, no ..)"
  end

  def extension_problem(block, path)
    extensions = FILE_EXTENSIONS[block.lang]
    return if extensions.nil? || extensions.any? { |ext| path.end_with?(ext) }

    "#{block.location}: file=#{path} should end in #{extensions.join(' or ')} for a #{block.lang} block"
  end

  def duplicate_file_problems(blocks)
    blocks.select(&:file?).group_by(&:path).filter_map do |path, same|
      bodies = same.map { |block| block.body.strip }.uniq
      next if bodies.size <= 1

      "file=#{path} appears with different content in #{same.map(&:location).join(', ')}: keep one copy and point to it"
    end
  end

  def handler_problems(block)
    return [] unless block.ruby? && block.body.match?(HANDLER)

    HANDLER_RULES.filter_map do |rule, why|
      hit = rule.is_a?(Proc) ? rule.call(block.body) : block.body.match?(rule)
      "#{block.location}: #{why}" if hit
    end
  end

  def ruby_program?(block)
    block.ruby? && (block.run? || block.file?)
  end

  # nil for valid Ruby, else the first error message (Ripper reports a
  # syntax error through these two callbacks; its own #parse returns nil).
  def syntax_error(source)
    errors = []
    checker = Class.new(Ripper) do
      define_method(:on_parse_error) { |message| errors << message }
      define_method(:compile_error) { |message| errors << message }
    end
    checker.new(source).parse
    errors.first
  end
end
