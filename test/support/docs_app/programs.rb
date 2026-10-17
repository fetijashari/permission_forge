# frozen_string_literal: true

module DocsApp
  # Runs the program of each document (DocBlocks::Document#program: its
  # `file=` and `run` blocks, in order) in the docs app: one console per
  # document (one binding, the app as installed), a `file=` block written
  # into the app and the app reloaded before the next block that runs, a
  # `# => literal` comment asserted (DocBlocks.literal?; anything else is
  # documentation).
  module Programs
    module_function

    # @return [Hash{String => Hash}] file => { blocks: [...] }
    def run_all(documents)
      documents.to_h { |document| [document.file, run_document(document)] }
    end

    # @param fresh [Boolean] start from the database as installed and seeded
    def run_document(document, fresh: true)
      Database.restore! if fresh
      console = Console.new
      blocks = document.program.map { |block| { location: block.location, marker: block.marker, lang: block.lang }.merge(console.run(block)) }
      console.settle!
      { blocks: blocks }
    end

    # The body of a block as a file: a block in a list item is indented with
    # the item, so the common indent goes. A blank line stays a line (its
    # spaces go, its newline stays).
    def dedent(body)
      indent = body.lines.reject { |line| line.strip.empty? }.map { |line| line[/\A */].size }.min.to_i
      body.lines.map { |line| line.strip.empty? ? line.sub(/\A[ \t]+/, '') : line[indent..] }.join
    end

    # Turns `expr # => literal` into a checked call. The expression becomes an
    # argument, not a block, so an assignment on that line still defines its
    # variable in the console's binding.
    def instrument(block)
      block.body.lines.each_with_index.map { |text, offset| instrumented_line(text, block.line + 1 + offset) }.join
    end

    # The line as written, unless it carries a literal claim on a standalone
    # expression.
    def instrumented_line(text, number)
      source, claim = text.chomp.split(/\s*#\s*=>\s*/, 2)
      return text if claim.nil? || !DocBlocks.literal?(claim.strip) || source.strip.empty? || DocBlocks.syntax_error(source)

      "__pf_expect(#{number}, #{claim.strip.inspect}, (#{source.strip}))\n"
    end

    # The object a document's code runs against: its locals live in the
    # binding, its `# =>` checks are recorded here.
    class Scope
      attr_reader :__pf_results

      def initialize
        @__pf_results = []
      end

      def __pf_binding = binding

      def __pf_expect(line, claim, actual)
        expected = Kernel.eval(claim, TOPLEVEL_BINDING.dup) # rubocop:disable Security/Eval -- a LITERAL of the doc's own grammar
        @__pf_results << { line: line, claim: claim, actual: actual.inspect, passed: actual == expected }
        actual
      end
    end

    # One document's console.
    class Console
      APP_FILES = %r{\Aapp/}

      def initialize
        @scope = Scope.new
        @binding = @scope.__pf_binding
        @reload = false
      end

      def run(block)
        return write(block) if block.file?

        settle!
        block.lang == 'bash' ? shell(block) : ruby(block)
      end

      # The app reloaded, when a file of it was written since the last run.
      def settle!
        return unless @reload

        Application.reload!
        @reload = false
      end

      private

      def write(block)
        path = File.join(Application.root, block.path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, Programs.dedent(block.body))
        note_written(block.path, path)
        { written: block.path }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      # A file under app/ is picked up by the next reload; an initializer or
      # a locale file is loaded now (nothing reloads those).
      def note_written(relative, path)
        if relative.start_with?('config/initializers/') then load path
        elsif relative.start_with?('config/locales/') then I18n.load_path << path and I18n.reload!
        elsif relative.match?(APP_FILES) then @reload = true
        end
      end

      def shell(block)
        lines = Shell.run(block.body)
        failed = lines.filter_map { |line| line[:error] }
        { lines: lines }.merge(failed.empty? ? {} : { error: failed.join('; ') })
      end

      def ruby(block)
        start = @scope.__pf_results.size
        output = Shell.capture { @binding.eval(Programs.instrument(block), block.file, block.line + 1) }
        { stdout: output[:stdout] }.merge(claims(start))
      rescue Exception => e # rubocop:disable Lint/RescueException -- a sample may `exit` or raise anything; the report says what
        failure(e, block).merge(claims(start))
      end

      def failure(error, block)
        { error: "#{error.class}: #{error.message}", at: error.backtrace&.find { |frame| frame.start_with?(block.file) } }
      end

      def claims(start) = { expectations: @scope.__pf_results[start..] }
    end
  end
end
