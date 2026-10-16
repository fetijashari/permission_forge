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

    # What a web server process has loaded before it boots the app:
    # `bin/rails server` (Rails::Server) and the `puma` command (Puma::CLI;
    # `require "puma"` alone defines neither). Another server (unicorn, thin,
    # falcon) counts as a process whose log is not read: its standard error
    # gets the warning unless the logger already writes there.
    SERVER_COMMANDS = %w[Rails::Server Puma::CLI].freeze

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
      # @return [String] the text written
      # @raise [ArgumentError] for a severity not in SEVERITIES
      def emit(key, message, severity: :config)
        text = "#{PREFIX}#{Warnings.severity_prefix(severity)}#{message}"
        Warnings.channels(@context).each do |channel|
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
      def emit(key, message, severity: :config)
        Emitter.new.emit(key, message, severity: severity)
      end

      # The channels a warning goes to under `context`: [] while a generator
      # runs, [:log] where the log is read, [:log, :terminal] elsewhere (see
      # the module).
      #
      # @param context [Context]
      # @return [Array<Symbol>]
      def channels(context = context())
        return [] if context.generator

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

      # Whether this process is a web server (SERVER_COMMANDS): its log is
      # where its warnings are read, outside development.
      #
      # @return [Boolean]
      def server_process?
        SERVER_COMMANDS.any? { |name| Object.const_defined?(name, false) }
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
