# frozen_string_literal: true

module PermissionForge
  module Audit
    # What happens when an audit write, a notification subscriber or a hook
    # fails, per the configured strategy:
    #   :raise  — the error propagates (a change event then rolls the change back)
    #   :report — logged at error level and handed to Rails.error as handled;
    #             execution continues
    #   :log    — logged only
    #
    # @api private
    module Failure
      SOURCE = 'permission_forge.audit'

      class << self
        # @param error [Exception]
        # @param strategy [Symbol] :raise, :report or :log
        # @param operation [Symbol] :store or :publish
        # @param details [Hash] event: and anything else worth knowing
        # @return [nil]
        def handle(error, strategy:, operation:, **details)
          raise error if strategy == :raise

          log(error, operation, details)
          report(error, operation, details) if strategy == :report
          nil
        end

        private

        def log(error, operation, details)
          return unless defined?(Rails) && Rails.logger

          what = details.map { |key, value| "#{key}=#{value}" }.join(' ')
          Rails.logger.error("[PermissionForge] audit #{operation} failed (#{what}) — #{error.class}: #{error.message}")
        end

        def report(error, operation, details)
          return unless defined?(Rails) && Rails.respond_to?(:error)

          Rails.error.report(error, handled: true, severity: :error, source: SOURCE, context: { operation: operation, **details })
        end
      end
    end
  end
end
