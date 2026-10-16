# frozen_string_literal: true

require 'test_helper'
require 'open3'
require_relative '../support/static_guard'
require_relative '../support/boot_test_helpers'

module PermissionForge
  # Every boot and configuration warning of the gem goes through one emitter,
  # PermissionForge::Warnings.emit, which decides the channel: the log always,
  # the terminal (standard error) where the log is not read — development, and
  # a console, runner, rake task, seed or job worker in any other environment —
  # unless the logger already writes there; nothing while a generator boots the
  # app; the terminal once per process and key. Before it, 25 sites chose
  # their channel one by one and only the development cache warning reached
  # standard error: every SECURITY warning (a fail-open condition) was in the
  # log only, which `bin/rails server` and `bin/rails runner` never show.
  #
  # Two guards:
  # - static: every `logger.warn`, `Kernel.warn`, bare `warn`, `$stderr` or
  #   `STDERR` in lib/ and app/ is the emitter's or in ALLOWLIST with a reason
  #   (a request-time log, a rake task's answer to its invoker, a deprecation);
  # - policy: the emitter with an injected environment, server flag, generator
  #   flag, logger and io writes where POLICY says, and once per key on the
  #   terminal. The dummy app booted as a development runner proves the
  #   defaults end to end.
  class BootWarningsChannelTest < ActiveSupport::TestCase
    include BootTestHelpers

    GLOBS = %w[lib/**/*.rb lib/**/*.rake lib/**/*.tt app/**/*.rb app/**/*.erb].freeze
    # A logger's warn, Kernel.warn, a bare `warn` (not `.warn`, `:warn`,
    # `warn:`, `warn =`, `warn ?` — a local —, `warn!` or `warn?`), $stderr,
    # STDERR — in code with strings blanked and comments stripped
    # (StaticGuard); a word in a `%w[]` / `%i[]` list (strategy names) is no
    # call (PERCENT_LITERAL).
    NEEDLE = /(?:logger&?|Kernel)\.warn\b|(?<![.\w:])warn\b(?![\w!?]|\s*[:=?])|\$stderr\b|\bSTDERR\b/
    PERCENT_LITERAL = /%[wiWI][\[({<][^\])}>]*[\])}>]/
    CANONICAL = %w[lib/permission_forge/warnings.rb].freeze

    RAKE_ANSWER = "a rake task's answer to its invoker: standard error is the task's own channel (RakeAudit)"
    REQUEST_TIME = 'a request-time log, written where the request is: no boot or configuration warning'
    ALLOWLIST = [
      ['lib/tasks/permission_forge_audit_events.rake', /warn "Refused: /, RAKE_ANSWER],
      ['lib/tasks/permission_forge.rake', /warn "FAIL_ON must be one of/, RAKE_ANSWER],
      ['lib/tasks/permission_forge.rake', /warn "Failing: /, RAKE_ANSWER],
      ['lib/tasks/permission_forge_gdpr.rake', /warn message/, RAKE_ANSWER],
      ['lib/permission_forge/rake_audit.rb', /def changing\(task, env: ENV, warn_io: \$stderr/, RAKE_ANSWER],
      ['lib/permission_forge/deprecation.rb', /def warn\(message, key: message/,
       'deprecations have a channel of their own: PermissionForge.deprecator (Rails.application.deprecators)'],
      ['lib/permission_forge/rls.rb', /Rails\.logger&\.warn\(/,
       'the result of a `permission_forge:rls:sync` run, logged by the run'],
      ['lib/permission_forge/virtual_fields.rb', /Rails\.logger&\.warn\("\[PermissionForge\] \#\{@klass\}/,
       "logged where a model's extra_fields_method raised; the boot-time consequence (its readers are not " \
       'masked) is VirtualReaders\' SECURITY warning through the emitter'],
      ['lib/permission_forge/audit.rb', /Rails\.logger&\.warn\("\[PermissionForge\] cannot check for the audit table/,
       'Audit owns the table check (once per process, Audit.verify_table!); lib/permission_forge/audit.rb is ' \
       'outside this change — route through Warnings.emit when it is next touched'],
      ['lib/permission_forge/audit.rb', /Rails\.logger\.warn\(BootWarnings\.missing_table\(name\)\)/,
       'Audit owns the table check (once per process, Audit.verify_table!); lib/permission_forge/audit.rb is ' \
       'outside this change — route through Warnings.emit when it is next touched'],
      ['lib/permission_forge/cache/withheld_notice.rb', /Rails\.logger\.warn\(/,
       'the "rebuilt inside a transaction" notice: request-time, once per process by itself'],
      ['lib/permission_forge/cache/rails_cache.rb', /Rails\.logger&\.warn\(/,
       'PermissionForge.cache.clear on a store that cannot match keys: the call that asked is told'],
      ['lib/permission_forge/admin/controller_catalog.rb', /Rails\.logger&\.warn\("\[PermissionForge\] controller catalog skipped/,
       REQUEST_TIME],
      ['lib/permission_forge/audit/settings_observer.rb', /could not record the audit settings/,
       'a write that failed (reported where it happened), not a configuration warning'],
      ['lib/permission_forge/services/filters_response_attributes.rb', /Rails\.logger\.warn\("PermissionForge: unconfigured field/,
       "#{REQUEST_TIME} (unconfigured_field_strategy = :warn)"],
      ['lib/permission_forge/services/unscoped_query_detector.rb', /Rails\.logger&\.warn\("\[PermissionForge\] \#\{message\} SQL:/,
       "#{REQUEST_TIME} (unscoped_query_detection = :log)"],
      ['lib/permission_forge/services/resource_field_generator.rb', /skipped \#\{skipped\} blank field name/,
       "#{REQUEST_TIME} (field generation)"],
      ['lib/permission_forge/concerns/permission_scoped_findable.rb', /current_user is nil — permission_scoped returns unscoped/,
       "#{REQUEST_TIME} (nil_user_strategy)"],
      ['lib/permission_forge/concerns/permission_scoped_findable.rb', /current_user is nil — bypassing row-level rules/,
       "#{REQUEST_TIME} (nil_user_strategy)"]
    ].freeze

    DEVELOPMENT = ActiveSupport::EnvironmentInquirer.new('development')
    TEST = ActiveSupport::EnvironmentInquirer.new('test')
    PRODUCTION = ActiveSupport::EnvironmentInquirer.new('production')

    # The channel policy: [environment, a server process?, a generator
    # running?, the logger already on the terminal?] => the channels.
    POLICY = {
      [DEVELOPMENT, false, false, false] => %i[log terminal], # console, runner, rake, db:seed
      [DEVELOPMENT, true, false, false] => %i[log terminal], # bin/rails server: it boots before its console logger attaches
      [DEVELOPMENT, false, false, true] => %i[log], # the log is already on the terminal
      [DEVELOPMENT, true, false, true] => %i[log],
      [DEVELOPMENT, false, true, false] => [], # bin/rails generate / destroy
      [TEST, false, false, false] => %i[log], # a test run reads its log and asserts
      [TEST, true, false, false] => %i[log],
      [PRODUCTION, true, false, false] => %i[log], # a server: its log is the record
      [PRODUCTION, false, false, false] => %i[log terminal], # console, runner, rake, seed, a job worker
      [PRODUCTION, false, false, true] => %i[log],
      [PRODUCTION, true, true, false] => [],
      [PRODUCTION, false, true, false] => []
    }.freeze

    DUMMY_APPLICATION = File.expand_path('../dummy/config/application', __dir__)

    setup { PermissionForge::Warnings.reset! }
    teardown { PermissionForge::Warnings.reset! }

    # ---- static guard ---------------------------------------------------------

    test 'every warning site in lib/ and app/ is the emitter or allow-listed with a reason' do
      hits = StaticGuard.scan(globs: GLOBS, needle: NEEDLE, canonical: CANONICAL, allowlist: ALLOWLIST)
                        .select { |hit| warning?(hit.line, erb: hit.file.end_with?('.erb')) }

      assert_empty hits.map(&:to_s),
                   'write boot/configuration warnings through PermissionForge::Warnings.emit(key, message, severity:); ' \
                   'a request-time log goes in ALLOWLIST with its reason'
    end

    test 'the allow-list and the canonical file are current' do
      StaticGuard.assert_allowlist_current(self, globs: GLOBS, needle: NEEDLE, canonical: CANONICAL, allowlist: ALLOWLIST)
    end

    # The negative fixture: what the needle must catch, and what it must leave alone.
    test 'the needle catches every way of writing a warning past the emitter and nothing else' do
      caught = ['Rails.logger.warn("x")', 'Rails.logger&.warn "x"', 'logger.warn(x)', 'Kernel.warn(message)',
                'warn "x"', '  warn message', '$stderr.puts(x)', 'STDERR.puts x', 'io = $stderr']
      left = ['PermissionForge::Deprecation.warn("x")', 'DEPRECATOR.warn(msg)', 'warn_io.puts(x)', 'warn_unmaskable(klass)',
              'logger.level = :warn', 'warn: lambda { }', 'config.log_level = :warn', '# Rails.logger.warn("in a comment")',
              'Rails.logger&.error("an error")', 'puts "logger.warn inside a string"', 'def warn? = risk == :warn',
              'def warn!(config)', 'options: %i[block pass_through warn mask_all]', '%w[pass_through warn].include?(x)',
              "<%= warn ? 'x' : 'y' %>"]

      caught.each { |line| assert warning?(line), "not caught: #{line}" }
      left.each { |line| assert_not warning?(line), "caught: #{line}" }
    end

    # ---- the channel policy -----------------------------------------------------

    test 'the emitter writes where the policy table says' do
      POLICY.each do |(env, server, generator, on_terminal), expected|
        logger = ActiveSupport::Logger.new(on_terminal ? $stdout : StringIO.new)
        context = PermissionForge::Warnings::Context.new(env: env, server: server, generator: generator, logger: logger)

        assert_equal expected, PermissionForge::Warnings.channels(context),
                     "env=#{env} server=#{server} generator=#{generator} logger on terminal=#{on_terminal}"
      end
    end

    test 'the default context is this process' do
      context = PermissionForge::Warnings.context

      assert_equal Rails.env, context.env
      assert_equal false, context.server
      assert_equal false, context.generator
      assert_same Rails.logger, context.logger
      assert_equal true, PermissionForge::Warnings.context(generator: true).generator, 'an override'
      assert_equal %i[log], PermissionForge::Warnings.channels, 'the test environment: the log only'
    end

    test 'a SECURITY warning is logged and written to the terminal with its prefix' do
      io = StringIO.new
      log = capture_rails_log do
        emitter(io, env: DEVELOPMENT).emit(:test_fail_open, 'this setup fails open.', severity: :security)
      end

      assert_includes log, '[PermissionForge] SECURITY warning: this setup fails open.'
      assert_equal "[PermissionForge] SECURITY warning: this setup fails open.\n", io.string
    end

    test 'a configuration warning carries the gem prefix only' do
      io = StringIO.new
      log = capture_rails_log { emitter(io, env: PRODUCTION, server: false).emit(:test_config, 'WARNING: a setting.') }

      assert_includes log, '[PermissionForge] WARNING: a setting.'
      assert_equal "[PermissionForge] WARNING: a setting.\n", io.string
    end

    test 'the terminal gets a key once per process; the log gets every emission the site makes' do
      io = StringIO.new
      log = capture_rails_log do
        3.times { emitter(io, env: DEVELOPMENT).emit(:test_repeat, 'again') }
        emitter(io, env: DEVELOPMENT).emit(:test_other, 'another key')
      end

      assert_equal 1, io.string.scan('again').size
      assert_equal 1, io.string.scan('another key').size
      assert_equal 3, log.scan('again').size

      PermissionForge::Warnings.reset!
      capture_rails_log { emitter(io, env: DEVELOPMENT).emit(:test_repeat, 'again') }
      assert_equal 2, io.string.scan('again').size, 'reset! forgets the keys written'
    end

    test 'nothing is written while a generator boots the app' do
      io = StringIO.new
      log = capture_rails_log do
        emitter(io, env: DEVELOPMENT, generator: true).emit(:test_generator, 'the defaults', severity: :security)
      end

      assert_empty io.string
      assert_empty log
    end

    test 'a terminal that cannot be written never raises, and the log still gets the warning' do
      io = StringIO.new
      io.close_write
      log = capture_rails_log do
        assert_nothing_raised { emitter(io, env: DEVELOPMENT).emit(:test_closed, 'closed terminal') }
      end

      assert_includes log, 'closed terminal'
    end

    test 'the severity is one of the table' do
      assert_raises(ArgumentError) { emitter(StringIO.new, env: DEVELOPMENT).emit(:test_bad, 'x', severity: :loud) }
      assert_equal %i[security config], PermissionForge::Warnings::SEVERITIES.keys
    end

    test 'Warnings.emit is an Emitter for this process' do
      log = capture_rails_log { PermissionForge::Warnings.emit(:test_process, 'through the module', severity: :security) }

      assert_includes log, '[PermissionForge] SECURITY warning: through the module'
    end

    test 'a logger that writes to standard output or error is on the terminal' do
      assert PermissionForge::Warnings.logger_on_terminal?(ActiveSupport::Logger.new($stdout))
      assert PermissionForge::Warnings.logger_on_terminal?(ActiveSupport::Logger.new($stderr))
      assert_not PermissionForge::Warnings.logger_on_terminal?(ActiveSupport::Logger.new(StringIO.new))
      assert_not PermissionForge::Warnings.logger_on_terminal?(nil)
    end

    # ---- which process this is -------------------------------------------------

    test 'a server process is one bin/rails server or the puma command started' do
      assert_not_predicate PermissionForge::Warnings, :server_process?, 'the test runner'
      assert_equal %w[Rails::Server Puma::CLI], PermissionForge::Warnings::SERVER_COMMANDS

      with_constant('Rails::Server') { assert_predicate PermissionForge::Warnings, :server_process? }
      assert_not_predicate PermissionForge::Warnings, :server_process?
    end

    test 'generator_running? has one definition, which BootChecks and Audit::BootWarnings delegate to' do
      assert_equal PermissionForge::Warnings::GENERATOR_COMMANDS, PermissionForge::BootChecks::GENERATOR_COMMANDS
      assert_not_predicate PermissionForge::Warnings, :generator_running?

      with_constant('Rails::Command::GenerateCommand') do
        assert_predicate PermissionForge::Warnings, :generator_running?
        assert_predicate PermissionForge::BootChecks, :generator_running?
        assert_predicate PermissionForge::Audit::BootWarnings, :generator_running?
      end
    end

    # ---- the defaults, end to end -------------------------------------------------

    # Field test: `bin/rails runner` and `db:seed` in development showed none
    # of the boot warnings (log/development.log only). The dummy boots as a
    # development runner would (no server command, a file logger, Rails'
    # development :memory_store, an empty in-memory database): every
    # applicable warning is on standard error once, and in the log.
    test 'a development runner prints each applicable warning once on standard error' do
      out, err, status = boot_dummy(logger_to_stdout: false)

      assert status.success?, "boot aborted (exit #{status.exitstatus}):\n#{out}\n#{err}"
      warnings = err.lines.grep(/\A\[PermissionForge\]/)
      assert_match(/Development: the permission cache is in memory \(cache_backend = :memory\), one per process/, err)
      assert_match(/auto-applied masking \(auto_apply_masked_attributes = :auto\) takes its models from the Resource rows/, err)
      assert_match(/Auto-applied masking is not complete at boot/, err, 'no Resource table in an empty database')
      assert_equal warnings.uniq, warnings, "a warning written twice:\n#{err}"
      assert_includes out, 'BOOTED', out
    end

    test 'a development runner whose logger is on standard output gets no second copy' do
      out, err, status = boot_dummy(logger_to_stdout: true)

      assert status.success?, "boot aborted (exit #{status.exitstatus}):\n#{out}\n#{err}"
      assert_match(/Development: the permission cache is/, out, 'logged')
      assert_empty err.lines.grep(/\A\[PermissionForge\]/), err
    end

    private

    # An emitter on `io` under this process's context with `overrides` (the
    # logger is Rails.logger: capture_rails_log sets it).
    def emitter(io, **overrides)
      PermissionForge::Warnings::Emitter.new(io: io, context: PermissionForge::Warnings.context(**overrides))
    end

    # Whether the line (its comment stripped, strings blanked) writes a
    # warning past the emitter.
    def warning?(line, erb: false)
      StaticGuard.code_of(line, erb: erb).gsub(PERCENT_LITERAL, '').match?(NEEDLE)
    end

    # Boots test/dummy in a child process as `bin/rails runner` would in
    # development: no server command loaded, an in-memory database with no
    # tables (nothing is written to disk).
    def boot_dummy(logger_to_stdout:)
      logger = logger_to_stdout ? 'Rails.application.config.logger = ActiveSupport::Logger.new($stdout)' : ''
      script = <<~RUBY
        require #{DUMMY_APPLICATION.dump}
        #{logger}
        Rails.application.initialize!
        puts 'BOOTED'
      RUBY
      env = { 'RAILS_ENV' => 'development', 'DATABASE_URL' => 'sqlite3::memory:', 'DB' => nil }
      Open3.capture3(env, RbConfig.ruby, '-e', script)
    end

    # Defines the constant `path` (a class) for the block, under the modules
    # it creates when missing, and removes what it added.
    def with_constant(path)
      skip "#{path} is loaded in this process" if Object.const_defined?(path, false)
      added = define_constant(path)
      yield
    ensure
      added&.reverse_each { |scope, name| scope.send(:remove_const, name) }
    end

    # @return [Array<Array(Module, String)>] what was defined, outermost first
    def define_constant(path)
      *namespaces, name = path.split('::')
      added = []
      parent = namespaces.inject(Object) do |scope, namespace|
        added << [scope, namespace] unless scope.const_defined?(namespace, false)
        scope.const_defined?(namespace, false) ? scope.const_get(namespace, false) : scope.const_set(namespace, Module.new)
      end
      parent.const_set(name, Class.new)
      added << [parent, name]
    end
  end
end
