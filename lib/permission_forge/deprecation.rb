# frozen_string_literal: true

module PermissionForge
  # The gem's deprecations: one ActiveSupport::Deprecation for every renamed
  # or removed public API (the README "Versioning and stability" surface).
  #
  # Convention: a public API is never renamed or removed in one step. The
  # release that changes it keeps the old name working for at least one
  # minor version, warning through {PermissionForge.deprecator}, and lists it
  # under "Deprecated" in the CHANGELOG; the release at HORIZON removes it.
  #
  #   # a renamed method or configuration option (reader and writer): the old
  #   # name calls the new one — not alias_method, which would skip the
  #   # writers Configuration prepends (validation, the preset's bookkeeping)
  #   def old_name = new_name
  #   def old_name=(value)
  #     self.new_name = value
  #   end
  #   PermissionForge.deprecator.deprecate_methods(self, old_name: :new_name, 'old_name=': :'new_name=')
  #   # a removed behaviour, warned once per process
  #   PermissionForge::Deprecation.warn('passing a String is deprecated; pass a Symbol')
  #
  # In a Rails application the deprecator is registered as
  # `Rails.application.deprecators[:permission_forge]`, so the host's
  # `config.active_support.deprecation` (:stderr, :log, :raise, :silence…),
  # `disallowed_deprecation` and `Rails.application.deprecators.silence { }`
  # govern it as they govern Rails' own.
  #
  # @api private
  module Deprecation
    # The version that removes what is deprecated now. A test fails once
    # VERSION reaches it: remove the deprecated code, then move the horizon.
    HORIZON = '0.15'
    GEM_NAME = 'PermissionForge'

    DEPRECATOR = ActiveSupport::Deprecation.new(HORIZON, GEM_NAME)

    WARNED_MUTEX = Mutex.new
    private_constant :WARNED_MUTEX

    @warned = Set.new

    class << self
      # @return [ActiveSupport::Deprecation]
      def deprecator = DEPRECATOR

      # Warns through the deprecator the first time `key` is seen in this
      # process, so a deprecated call on a hot path does not flood the log.
      # A warning that raised (behavior :raise) or was silenced is not
      # remembered: the next call warns (or raises) again. The message says
      # what to use instead; the version that removes it is added.
      #
      # @param message [String] e.g. "passing a String is deprecated; pass a Symbol"
      # @param key [Object] what "once" is counted by (default: the message)
      # @return [void]
      def warn(message, key: message, callstack: caller_locations(1))
        return if WARNED_MUTEX.synchronize { @warned.include?(key) }

        DEPRECATOR.warn("#{message}. #{GEM_NAME} #{HORIZON} removes it.", callstack)
        WARNED_MUTEX.synchronize { @warned << key } unless DEPRECATOR.silenced
      end

      # Forgets which keys warned (for tests that check a warning).
      #
      # @return [void]
      def reset!
        WARNED_MUTEX.synchronize { @warned.clear }
      end

      # Hands the deprecator to the application's deprecators (Rails 7.1+).
      #
      # @param app [Rails::Application]
      # @return [void]
      def register(app)
        app.deprecators[:permission_forge] = DEPRECATOR if app.respond_to?(:deprecators)
      end
    end
  end

  # @return [ActiveSupport::Deprecation] the gem's deprecator
  def self.deprecator = Deprecation.deprecator
end

# Runs when the application starts initializing, or at once when it already
# has (the gem required late).
ActiveSupport.on_load(:before_initialize, yield: true) { |app| PermissionForge::Deprecation.register(app) }
