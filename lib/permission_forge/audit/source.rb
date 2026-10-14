# frozen_string_literal: true

module PermissionForge
  module Audit
    # Where an event came from: the source column. The admin UI, the API and
    # jobs say so through the audit context (Audit::Context); a process that
    # says nothing is a console, a rake task, or else a service.
    #
    # @api private
    module Source
      SOURCES = %w[admin_ui api rake job console service runtime].freeze

      class << self
        # @return [String] the context's source, else the detected one
        def current
          Context[:source] || detect
        end

        # @param console [Boolean] whether this process is `rails console`
        # @param rake_tasks [Array<String>] the tasks rake was started with
        # @return [String]
        def detect(console: process_console?, rake_tasks: process_rake_tasks)
          return 'console' if console
          return 'rake' if rake_tasks.any?

          'service'
        end

        # @raise [ArgumentError] for a source outside the contract
        # @return [String]
        def validate!(value)
          source = value.to_s
          raise ArgumentError, "audit source must be one of #{SOURCES.join(', ')} (got #{value.inspect})" unless SOURCES.include?(source)

          source
        end

        private

        def process_console?
          defined?(::Rails::Console) ? true : false
        end

        # Rake is loaded in a test process too: only a process started with a
        # task is a rake task.
        def process_rake_tasks
          return [] unless defined?(::Rake::Application) && ::Rake.respond_to?(:application)

          ::Rake.application.top_level_tasks
        end
      end
    end
  end
end
