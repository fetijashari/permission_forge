# frozen_string_literal: true

module PermissionForge
  module ControllerActions
    # Decides whether a user may run a controller action. The runtime guard
    # ({PermissionForge::Concerns::ControllerActionGuard}) raises on a denied
    # decision; host apps call {.allowed?} to hide buttons with the same logic.
    #
    # Decision order — the first row that applies wins:
    #   1. the action maps to no Resource (Mapping returns nil)     → allow
    #   2. no user → action_guard_nil_user_strategy, else nil_user_strategy → :bypass allows, anything else denies
    #   3. config.action_guard_bypass returns true                  → allow
    #   4. no Permission Set manages the Resource                   → unconfigured_action_strategy
    #   5. the action means a CRUD permission                       → user.can?(crud, resource)
    #   6. custom action the user is granted                        → allow
    #   7. custom action some Permission Set manages                → deny
    #   8. custom action no Permission Set manages                  → unconfigured_action_strategy
    #
    # A grant (rows 5 and 6) is checked before the index, so a granted request
    # costs no extra cache read; rows 4, 7 and 8 share one. Everything
    # unexpected fails closed: a user object without `can?`, a bypass lambda
    # that raises or returns something other than true, an unknown strategy.
    #
    # @example
    #   Authorizer.call(controller_path: 'customers', action_name: 'export')
    #   # => #<struct allowed=false, reason=:action_denied, target=#<struct resource="Customer", ...>>
    #   Authorizer.allowed?(controller_path: 'customers', action_name: 'export', user: current_user)
    #   # => false
    #
    # @api public
    class Authorizer
      # Every outcome and whether it lets the request through.
      REASONS = {
        unmapped: true,                       # row 1
        nil_user_bypassed: true,              # row 2, the nil-user strategy is :bypass
        nil_user_denied: false,               # row 2, any other nil-user strategy
        guard_bypassed: true,                 # row 3
        unsupported_user: false,              # the user object has no can?
        resource_not_managed: true,           # row 4, unconfigured_action_strategy = :allow
        resource_not_managed_blocked: false,  # row 4, any other strategy
        crud_granted: true,                   # row 5
        crud_denied: false,                   # row 5
        action_granted: true,                 # row 6
        action_denied: false,                 # row 7
        action_not_managed: true,             # row 8, unconfigured_action_strategy = :allow
        action_not_managed_blocked: false     # row 8, any other strategy
      }.freeze

      # The allowed outcomes that let a request past the Permission Sets, and
      # the rule.bypassed reason each one is published with (the guard does
      # it: Authorizer.allowed? also answers button checks).
      BYPASS_REASONS = {
        nil_user_bypassed: 'nil_user',
        guard_bypassed: 'guard_bypass',
        resource_not_managed: 'no_rules',
        action_not_managed: 'no_rules'
      }.freeze

      # target is the Mapping::Target that was checked, or nil when the action
      # maps to no Resource. Every denied decision carries a target.
      #
      # @api private
      Decision = Struct.new(:allowed, :reason, :target, keyword_init: true) do
        def allowed? = allowed == true
        def denied? = !allowed?

        # @return [String, nil] the rule.bypassed reason, for an allowed
        #   decision that skipped the Permission Sets
        def bypass_reason = BYPASS_REASONS[reason]
      end

      # @param controller_path [String] e.g. 'customers/merges'
      # @param action_name [String, Symbol] e.g. 'create'
      # @param controller_class [Class, nil] the controller, for its
      #   `permission_forge_actions` declaration. Defaults to the controller's
      #   class, then to the class the path names (`Customers::MergesController`).
      # @param controller [Object, nil] the controller instance, handed to
      #   config.action_guard_bypass
      # @param user [Object, nil] defaults to PermissionForge.current_user
      # @param configuration [PermissionForge::Configuration]
      # @param index [#managed_actions] defaults to ManagedIndex
      # @return [Decision]
      def self.call(...) = new(...).call

      # Same arguments as {.call}.
      #
      # @return [Boolean] whether the user may run the action
      def self.allowed?(...) = call(...).allowed?

      # What to check, plus the injectable dependencies — all keywords.
      def initialize(controller_path:, action_name:, controller_class: nil, controller: nil, # rubocop:disable Metrics/ParameterLists
                     user: PermissionForge.current_user, configuration: PermissionForge.configuration,
                     index: ManagedIndex)
        @controller_path = controller_path.to_s
        @action_name = action_name.to_s
        @controller = controller
        # No controller given (a button check): the class the path names.
        @controller_class = controller_class || controller&.class || ControllerActions.controller_class_for(@controller_path)
        @user = user
        @configuration = configuration
        @index = index
      end

      # @return [Decision]
      def call
        @target = Mapping.call(controller_path: @controller_path, action_name: @action_name,
                               controller_class: @controller_class, configuration: @configuration)
        return decide(:unmapped) unless @target
        return decide(nil_user_bypass? ? :nil_user_bypassed : :nil_user_denied) unless @user
        return decide(:guard_bypassed) if guard_bypassed?
        return decide(:unsupported_user) unless @user.respond_to?(:can?)

        authorize
      end

      private

      # Rows 4–8: what the Permission Sets say. A grant is checked first — a
      # user can only be granted something on a managed resource, so the answer
      # is the same and a granted request never reads the index. Everything
      # else costs one index read.
      def authorize
        return decide(@target.crud? ? :crud_granted : :action_granted) if can?(@target.permission)

        managed_actions = @index.managed_actions(@target.resource)
        return unconfigured(:resource_not_managed) if managed_actions.nil?
        return decide(:crud_denied) if @target.crud?
        return decide(:action_denied) if managed_actions.include?(@target.action)

        unconfigured(:action_not_managed)
      end

      def decide(reason)
        Decision.new(allowed: REASONS.fetch(reason), reason: reason, target: @target)
      end

      # Nobody configured this resource or action: the strategy decides.
      def unconfigured(reason)
        decide(@configuration.allow_unconfigured_actions? ? reason : :"#{reason}_blocked")
      end

      # Only an explicit true from can? grants.
      def can?(permission)
        @user.can?(permission, @target.resource) == true
      end

      # Only the exact :bypass value lets a request with no user through.
      def nil_user_bypass?
        @configuration.action_guard_nil_user_bypass?
      end

      # Only an explicit true skips the guard. A raising (or non-callable)
      # bypass counts as "no bypass": the Permission Sets still decide.
      def guard_bypassed?
        bypass = @configuration.action_guard_bypass
        return false if bypass.nil?

        bypass.call(@user, @controller) == true
      rescue StandardError => e
        log_bypass_error(e)
        false
      end

      def log_bypass_error(error)
        return unless defined?(Rails) && Rails.respond_to?(:logger)

        Rails.logger&.error("[PermissionForge] action_guard_bypass error: #{error.class}: #{error.message}")
      end
    end
  end
end
