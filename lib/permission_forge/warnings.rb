# frozen_string_literal: true

require 'concurrent/map'

module PermissionForge
  # The one emitter of the gem's boot and configuration warnings (a per-process
  # cache, a fail-open setting, a model that cannot be masked, ...). Every such
  # warning is one `emit` call; this module decides the channel, so that a
  # warning about a fail-open condition is read by somebody.
  #
  # The channel policy (`channels`):
  # - the log (Rails.logger.warn) always;
  # - the terminal (standard error) where the log is not read: in development
  #   (`bin/rails server` boots before it attaches its console logger; a
  #   console, `bin/rails runner`, a rake task and `db:seed` never attach one)
  #   and, in every other environment but test, in any process that is not a
  #   web server (a console, a runner, a rake task, a seed, a job worker) —
  #   unless the logger already writes to standard output or error (a
  #   container, RAILS_LOG_TO_STDOUT), which would print it twice;
  # - nothing while `bin/rails generate` or `destroy` boots the app
  #   (generator_running?): the install generator boots before it writes the
  #   initializer, so its warnings describe a configuration the app is about
  #   to stop having (R5 #120);
  # - the terminal gets a key once per process (a human needs one line); the
  #   log gets every emission the site makes — a site that may repeat (a
  #   retried model, a store outage) decides itself when its condition is new.
  #
  # A SECURITY warning (severity :security) is a condition under which access
  # is wider than configured, or a change goes unrecorded; it carries the
  # prefix `SECURITY warning:`. Adding a severity is one SEVERITIES entry.
  #
  # A warning's audience (AUDIENCES) is the processes it is about. :all (the
  # default): every process — the cache, the models, the rules, the audit
  # table are used by a runner, a rake task, a job as much as by a server.
  # :server: a warning about the admin screens or the JSON API, which only
  # a web server process serves (HTTP Basic credentials, the actor of an
  # admin change, the API's authorization lambdas, an API-only host's
  # middlewares, tenantless admin access); outside a server process
  # (server_process?) it goes to the log only. A runner does not serve the
  # admin, and the credentials it would warn about are often set for the
  # server alone (round 7, a-onboarding #23).
  #
  # Nothing here raises for a channel: a terminal that cannot be written is
  # skipped, a missing logger is skipped. Never called at require time.
  #
  # @example
  #   PermissionForge::Warnings.emit(:api_authorization_gap,
  #                                  'API is enabled but ... (privilege escalation).', severity: :security)
  #
  # @api private
  module Warnings
    # The text each severity puts before the message.
    SEVERITIES = { security: 'SECURITY warning: ', config: '' }.freeze

    # Every warning starts with it.
    PREFIX = '[PermissionForge] '

    # The commands `bin/rails generate` and `bin/rails destroy` run: Rails
    # loads the command's class before it boots the app (canary
    # :generator_commands). Rails::Generators alone does not say it: a gem may
    # require rails/generators as it loads.
    GENERATOR_COMMANDS = %w[Rails::Command::GenerateCommand Rails::Command::DestroyCommand].freeze

    # The processes a warning is about (see the module): every process, or
    # a web server's only. Adding an audience is one entry here and a rule
    # in .channels.
    AUDIENCES = %i[all server].freeze

    # What a web server's own command has loaded before it boots the app,
    # never what `require "<gem>"` (Bundler.require in a runner) loads:
    # `bin/rails server` (Rails::Server), `puma` (Puma::CLI), `unicorn` and
    # `unicorn_rails` (Unicorn::Launcher), Passenger's Rack loaders
    # (PhusionPassenger::App), `falcon serve` / `falcon host`
    # (Falcon::Command). Another server (thin, a custom Rack launcher)
    # counts as a process whose log is not read: its standard error gets
    # the warning unless the logger already writes there, and a :server
    # warning goes to its log only.
    SERVER_COMMANDS = %w[Rails::Server Puma::CLI Unicorn::Launcher PhusionPassenger::App Falcon::Command].freeze

    # Servers whose command defines no constant of its own, by program name
    # (the basename of Process.argv0, the name the process was started
    # with, or of $PROGRAM_NAME): `pitchfork` (bin/pitchfork requires what
    # `require "pitchfork"` does, and pitchfork rewrites $0 into its process
    # title: Process.argv0 keeps the name), `rackup` (`bundle exec rackup`
    # boots Rack's handler, never Puma::CLI; `bundle exec` loads a Ruby
    # binstub in its own process and sets $0 to it, so Process.argv0 reads
    # `bundle` there). A server started some other way counts as a process
    # whose log is not read (see SERVER_COMMANDS).
    SERVER_PROGRAMS = %w[pitchfork rackup].freeze

    # The channels, in writing order.
    CHANNELS = %i[log terminal].freeze

    # What the channel policy reads about the process a warning is written
    # from: the environment (an ActiveSupport::EnvironmentInquirer), whether
    # it is a web server, whether a generator is booting it, and its logger.
    # Warnings.context builds the current one; tests build their own.
    Context = Data.define(:env, :server, :generator, :logger)

    # Writes warnings to a terminal under a Context. Warnings.emit uses one
    # for this process; tests inject an io and a Context.
    class Emitter
      # @param io [IO] the terminal
      # @param context [Context]
      def initialize(io: $stderr, context: Warnings.context)
        @io = io
        @context = context
      end

      # @param key [Symbol, String] what the warning is about (the terminal
      #   gets each key once per process); a per-subject warning puts the
      #   subject in the key (`"masked_models.unmaskable.#{name}"`)
      # @param message [String] the sentence(s), without the gem prefix: it
      #   names the condition, its consequence and the remedy
      # @param severity [Symbol] a SEVERITIES key: :security for a condition
      #   under which access widens or a change goes unrecorded, else :config
      # @param audience [Symbol] an AUDIENCES entry: :server for a warning
      #   about the admin or the API a server process serves (the log only
      #   in any other process), else :all
      # @return [String] the text written
      # @raise [ArgumentError] for a severity not in SEVERITIES, an audience
      #   not in AUDIENCES
      def emit(key, message, severity: :config, audience: :all)
        text = "#{PREFIX}#{Warnings.severity_prefix(severity)}#{message}"
        Warnings.channels(@context, audience: audience).each do |channel|
          channel == :log ? @context.logger&.warn(text) : terminal(key, text)
        end
        text
      end

      private

      # Once per process and key. A terminal that is closed or gone (a
      # broken pipe) is skipped: the log has the warning.
      def terminal(key, text)
        return unless Warnings.first_on_terminal?(key)

        @io.puts(text)
      rescue IOError, SystemCallError
        nil
      end
    end

    class << self
      # Writes one warning where the policy says (an Emitter for this process).
      #
      # @param (see Emitter#emit)
      # @return [String] the text written
      def emit(key, message, severity: :config, audience: :all)
        Emitter.new.emit(key, message, severity: severity, audience: audience)
      end

      # The channels a warning goes to under `context`: [] while a generator
      # runs, [:log] where the log is read — and for a :server warning in a
      # process that is not a server —, [:log, :terminal] elsewhere (see the
      # module).
      #
      # @param context [Context]
      # @param audience [Symbol] an AUDIENCES entry
      # @return [Array<Symbol>]
      # @raise [ArgumentError] for an audience not in AUDIENCES
      def channels(context = context(), audience: :all)
        check_audience!(audience)
        return [] if context.generator
        return CHANNELS.first(1) if audience == :server && !context.server

        terminal?(context) ? CHANNELS : CHANNELS.first(1)
      end

      # This process, with `overrides` for a test.
      #
      # @param overrides [Hash] env:, server:, generator:, logger:
      # @return [Context]
      def context(**overrides)
        current = { env: Rails.env, server: server_process?, generator: generator_running?, logger: current_logger }
        Context.new(**current, **overrides)
      end

      # Forgets which keys the terminal got (tests; a process has one boot).
      #
      # @return [void]
      def reset!
        written.clear
      end

      # Whether `bin/rails generate` or `bin/rails destroy` is booting the
      # app: their command class is loaded; a server, a console, a runner or
      # a rake task loads its own.
      #
      # @return [Boolean]
      def generator_running?
        GENERATOR_COMMANDS.any? { |name| Object.const_defined?(name, false) }
      end

      # Whether this process is a web server (SERVER_COMMANDS,
      # SERVER_PROGRAMS): its log is where its warnings are read, outside
      # development, and the :server warnings are about it.
      #
      # @param started_as [String] the name the process was started with (Process.argv0)
      # @param program_name [String] $PROGRAM_NAME as it is now
      # @return [Boolean]
      def server_process?(started_as: Process.argv0, program_name: $PROGRAM_NAME)
        SERVER_COMMANDS.any? { |name| Object.const_defined?(name, false) } ||
          [started_as, program_name].any? { |program| SERVER_PROGRAMS.include?(File.basename(program.to_s)) }
      end

      # Whether `logger` already writes to standard output or error (a
      # container setup, RAILS_LOG_TO_STDOUT, a logger the app configured):
      # the terminal then has the warning once the log is written.
      #
      # @param logger [Logger, nil]
      # @return [Boolean]
      def logger_on_terminal?(logger = current_logger)
        !logger.nil? && ActiveSupport::Logger.logger_outputs_to?(logger, $stdout, $stderr)
      end

      # @param severity [Symbol]
      # @return [String] what SEVERITIES puts before the message
      # @raise [ArgumentError] for a severity not in SEVERITIES
      def severity_prefix(severity)
        SEVERITIES.fetch(severity) do
          raise ArgumentError, "unknown warning severity #{severity.inspect}; one of #{SEVERITIES.keys.inspect}"
        end
      end

      # Whether the terminal has not had `key` in this process yet (and
      # remembers that it now has).
      #
      # @param key [Symbol, String]
      # @return [Boolean]
      def first_on_terminal?(key)
        written.put_if_absent(key.to_s, true).nil?
      end

      private

      def check_audience!(audience)
        return if AUDIENCES.include?(audience)

        raise ArgumentError, "unknown warning audience #{audience.inspect}; one of #{AUDIENCES.inspect}"
      end

      # Rails.logger, nil before the app has one.
      def current_logger
        Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
      end

      # Never in test (a test run reads its log); in development always; in
      # any other environment in a process that is not a server — each unless
      # the log already shows on the terminal.
      def terminal?(context)
        env = context.env
        return false if env.test?

        (env.development? || !context.server) && !logger_on_terminal?(context.logger)
      end

      def written
        @written ||= Concurrent::Map.new
      end
    end
  end
end
