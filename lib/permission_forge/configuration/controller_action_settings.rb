# frozen_string_literal: true

module PermissionForge
  class Configuration
    # Options for controller actions: discovery in the admin and the runtime
    # guard ({PermissionForge::Concerns::ControllerActionGuard}).
    #
    # @api public
    module ControllerActionSettings
      # Rails' own controllers never show up in discovery or get guarded.
      DEFAULT_CONTROLLER_DISCOVERY_EXCLUDE = [
        %r{\A(rails|active_storage|action_mailbox|action_cable|action_text|turbo)(/|\z)}
      ].freeze

      # When true, a Resource's Actions tab lists the host app's controller
      # actions that map to that resource. Default: false.
      attr_accessor :controller_action_discovery

      # Maps a controller action to a Resource and an action key. Receives
      # (controller_path, action_name) — e.g. ('customers/merges', 'create').
      #
      #   ['Customer', 'merge'] — this Resource, this action key
      #   false                 — never managed (not listed, not guarded)
      #   nil                   — use the convention (controller name → model)
      #
      #   config.controller_action_resolver = lambda do |controller_path, action_name|
      #     ['Customer', 'merge'] if controller_path == 'customers/merges' && action_name == 'create'
      #   end
      attr_accessor :controller_action_resolver

      # Controllers left out of discovery and the guard: Regexps, or Strings
      # naming a controller or a namespace ('webhooks' leaves out `webhooks`
      # and `webhooks/*`, not `webhooks_admin`). Blank entries are ignored.
      # PermissionForge's own controllers are always excluded.
      attr_accessor :controller_discovery_exclude

      # What the guard does with a resource or action no Permission Set manages:
      #
      #   :block — deny until a Permission Set permits it (default since 0.15)
      #   :allow — let it through: nothing is restricted until an admin adds the
      #            action to a Permission Set (the default before 0.15; an
      #            explicit opt-out that fails open, reported by SecurityAudit)
      #
      # A String is taken as its Symbol; any other value raises
      # ConfigurationError (StrategyValues).
      attr_accessor :unconfigured_action_strategy

      # Lambda(user, controller) returning true to skip the guard for this
      # request (e.g. ->(user, _controller) { user.admin? }). Default: nil.
      attr_accessor :action_guard_bypass

      # What the guard does with a mapped action when there is no current
      # user, apart from nil_user_strategy (which keeps governing record
      # rules and masking):
      #
      #   nil     — follow nil_user_strategy (default: no change for existing apps)
      #   :bypass — let the request through
      #   :deny   — refuse it (PermissionForge::ActionNotAuthorizedError)
      #
      # :raise refuses too; nil or blank follows nil_user_strategy; a String
      # is taken as its Symbol; any other value raises ConfigurationError
      # (StrategyValues). New installs get :deny in the
      # generated initializer.
      attr_accessor :action_guard_nil_user_strategy

      # Sets this group's defaults; called from Configuration#initialize.
      # @return [void]
      # @api private
      def set_controller_action_defaults
        @controller_action_discovery = false
        @controller_action_resolver = nil
        @controller_discovery_exclude = DEFAULT_CONTROLLER_DISCOVERY_EXCLUDE.dup
        @unconfigured_action_strategy = :block
        @action_guard_bypass = nil
        @action_guard_nil_user_strategy = nil
      end

      # @return [Boolean] whether the guard lets a request with no user
      #   through: action_guard_nil_user_strategy, else nil_user_strategy.
      #   Only the exact :bypass value lets it through.
      def action_guard_nil_user_bypass?
        (action_guard_nil_user_strategy.presence || nil_user_strategy).to_s == 'bypass'
      end

      # @return [Boolean] whether the admin lists the app's controller actions.
      def controller_action_discovery?
        controller_action_discovery == true
      end

      # @return [Boolean] whether an unmanaged resource or action passes the
      #   guard. Only the exact :allow value allows.
      def allow_unconfigured_actions?
        unconfigured_action_strategy.to_s == 'allow'
      end

      # @param controller_path [String] e.g. 'api/v1/customers'
      # @return [Boolean] whether the controller is outside discovery and the guard.
      def controller_excluded?(controller_path)
        path = controller_path.to_s
        return true if path == 'permission_forge' || path.start_with?('permission_forge/')

        Array(controller_discovery_exclude).any? do |pattern|
          next pattern.match?(path) if pattern.is_a?(Regexp)

          # A blank String (an unset ENV value) must not exclude everything,
          # and 'custom' must not exclude 'customers'.
          prefix = pattern.to_s.chomp('/')
          prefix.present? && (path == prefix || path.start_with?("#{prefix}/"))
        end
      end
    end
  end
end
