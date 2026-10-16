# frozen_string_literal: true

module PermissionForge
  # The one reading of DRY_RUN= for the gem's rake tasks that delete data
  # (`permission_forge:erasure`, `permission_forge:audit_events:purge`). Only
  # an explicit false (`false`, `0`, `no`, any case) runs for real; any other
  # value (`true`, `1`, `yes`, a typo) is a dry run. Unset or empty, the task
  # keeps its own default: the erasure is a dry run, the purge deletes (a
  # scheduled purge must not silently stop).
  #
  #   dry_run = PermissionForge::RakeDryRun.dry_run?(ENV.fetch('DRY_RUN', nil), default: true)
  #
  # The task reads the variable itself, so the rake lints see it read.
  #
  # @api private
  module RakeDryRun
    # The values that run a task for real.
    EXECUTE = %w[false 0 no].freeze

    module_function

    # @param value [String, nil] what DRY_RUN= was set to
    # @param default [Boolean] the answer when it is unset or empty
    # @return [Boolean] whether the task only counts
    def dry_run?(value, default:)
      given = value.to_s.strip.downcase
      return default if given.empty?

      !EXECUTE.include?(given)
    end
  end
end
