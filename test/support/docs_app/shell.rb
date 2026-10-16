# frozen_string_literal: true

require 'shellwords'
require_relative '../rake_tasks'

module DocsApp
  # A ```bash run block, line by line, inside the app's process: the gem's
  # rake tasks (`rake permission_forge:x`, `bin/rails permission_forge:x`,
  # with `VAR=value` in front), the install generator, `db:migrate`, and the
  # lines a reader types that need nothing here (`bundle install`, `rails
  # console`). Any other line is an error: the block must be a fragment.
  module Shell
    ASSIGNMENT = /\A[A-Z_][A-Z0-9_]*=/
    RUNNERS = %w[bin/rails rails rake bundle].freeze
    NOOPS = { 'bundle install' => 'the bundle is this process', 'rails console' => 'the ruby blocks that follow are the console' }.freeze

    Line = Struct.new(:text, :env, :words, keyword_init: true)

    module_function

    # @return [Array<Hash>] one entry per line run: the line and its outcome
    def run(body)
      lines(body).map { |line| { line: line.text }.merge(run_line(line)) }
    end

    # The command lines of a block: comments and blanks dropped, a trailing
    # comment removed, `VAR=value` pairs split off.
    def lines(body)
      body.lines.filter_map do |raw|
        text = raw.chomp.sub(/\s+#.*\z/, '').strip
        next if text.empty? || text.start_with?('#')

        words = Shellwords.split(text)
        env = {}
        env.store(*words.shift.split('=', 2)) while words.first&.match?(ASSIGNMENT)
        Line.new(text: text, env: env, words: words)
      end
    end

    def run_line(line)
      words = line.words.dup
      words.shift(2) if words.first(2) == %w[bundle exec]
      runner = RUNNERS.include?(words.first) ? words.shift : nil
      command = [runner, *words].compact.join(' ')
      return { noop: NOOPS.fetch(command) } if NOOPS.key?(command)

      dispatch(words, line.env, runner)
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end

    def dispatch(words, env, runner)
      case words
      in ['generate' | 'g', 'permission_forge:install', *flags] then Install.generate(flags)
      in ['db:migrate'] then Install.migrate
      in [/\Apermission_forge:/ => task] then rake(task, env)
      else { error: "unsupported shell line (#{runner} #{words.join(' ')}): mark the block `fragment` or teach docs_app/shell.rb" }
      end
    end

    # One of the gem's tasks, with the line's ENV for its duration.
    def rake(name, env)
      application = RakeTasks.application
      raise ArgumentError, "#{name} is not a rake task of the gem" unless application.lookup(name)

      with_env(env) do
        capture do |status|
          previous = Rake.application
          Rake.application = application
          application.tasks.each(&:reenable)
          begin
            application[name].invoke
          rescue SystemExit => e
            status[:exit] = e.status
          ensure
            Rake.application = previous
          end
        end
      end
    end

    def with_env(env)
      saved = env.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      env.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    # stdout and stderr of a line, and the status it exited with (nil: none).
    def capture
      out = StringIO.new
      err = StringIO.new
      status = {}
      previous_out = $stdout
      previous_err = $stderr
      $stdout = out
      $stderr = err
      yield status
      { stdout: out.string, stderr: err.string, exit: status[:exit] }
    ensure
      $stdout = previous_out
      $stderr = previous_err
    end
  end
end
