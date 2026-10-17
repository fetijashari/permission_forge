require 'test_helper'

module PermissionForge
  module ControllerActions
    class ControllerActionGuardTest < ActiveSupport::TestCase
      GUARD = PermissionForge::Concerns::ControllerActionGuard

      setup do
        @user = create_user
        @set = create_permission_set
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @set)
        Current.user = @user
      end

      def controller_for(klass, action)
        klass.new.tap { |controller| controller.action_name = action }
      end

      def authorize(klass, action)
        controller_for(klass, action).send(:pf_authorize_action!)
      end

      # --- declaration ------------------------------------------------------------

      test 'a guarded controller starts with the empty declaration' do
        assert_same PermissionForge::ControllerActions::EMPTY_OPTIONS, ::CustomersController.pf_action_guard_options
      end

      test 'permission_forge_actions stores the normalized, frozen declaration' do
        options = ::Customers::MergesController.pf_action_guard_options

        assert_equal({ resource: 'Customer', actions: { 'create' => 'merge' }, rest_actions: true }, options)
        assert_predicate options, :frozen?
        assert_predicate options[:actions], :frozen?
      end

      test 'permission_forge_actions accepts a model class, symbols and rest_actions: false' do
        controller = Class.new(::ApplicationController) do
          include GUARD

          permission_forge_actions resource: ::Customer, actions: { approve: :edit }, rest_actions: false
        end

        assert_equal({ resource: 'Customer', actions: { 'approve' => 'edit' }, rest_actions: false },
                     controller.pf_action_guard_options)
      end

      test 'a declaration the mapping could not use fails when the controller loads' do
        declare = lambda do |**options|
          Class.new(::ApplicationController) do
            include GUARD

            permission_forge_actions(**options)
          end
        end

        error = assert_raises(ArgumentError) { declare.call(resource: 'customer') }
        assert_includes error.message, '"customer" is not a Resource name'

        assert_raises(ArgumentError) { declare.call(resource: 'Customer Record') }

        error = assert_raises(ArgumentError) { declare.call(actions: { create: 'Merge', update: :merge!, show: nil }) }
        assert_includes error.message, 'invalid action key "Merge", "merge!", ""'

        assert_nothing_raised { declare.call(resource: 'Billing::Invoice', actions: { create: 'merge_v2', approve: :edit }) }
        assert_nothing_raised { declare.call(resource: nil, actions: {}) }
      end

      test 'a rejected declaration leaves the inherited one in place' do
        subclass = Class.new(::Customers::MergesController)

        assert_raises(ArgumentError) { subclass.permission_forge_actions(resource: 'customer') }
        assert_same ::Customers::MergesController.pf_action_guard_options, subclass.pf_action_guard_options
      end

      test 'a subclass inherits the declaration' do
        subclass = Class.new(::Customers::MergesController)

        assert_same ::Customers::MergesController.pf_action_guard_options, subclass.pf_action_guard_options
      end

      test 'a subclass declaration adds to the inherited one, for that subclass only' do
        subclass = Class.new(::Customers::MergesController) do
          permission_forge_actions actions: { create: :combine, destroy: :split }, rest_actions: false
        end
        sibling = Class.new(::Customers::MergesController)

        assert_equal({ resource: 'Customer', actions: { 'create' => 'combine', 'destroy' => 'split' }, rest_actions: false },
                     subclass.pf_action_guard_options)
        assert_equal({ resource: 'Customer', actions: { 'create' => 'merge' }, rest_actions: true },
                     ::Customers::MergesController.pf_action_guard_options)
        assert_same ::Customers::MergesController.pf_action_guard_options, sibling.pf_action_guard_options
      end

      # Replacing would leave `resource: nil` after the second call: the
      # controller would map to nothing and go unchecked.
      test 'declaring twice in one class keeps what the first call named' do
        controller = Class.new(::ApplicationController) do
          include GUARD

          permission_forge_actions resource: 'Customer', rest_actions: false
          permission_forge_actions actions: { create: :merge }
        end

        assert_equal({ resource: 'Customer', actions: { 'create' => 'merge' }, rest_actions: false },
                     controller.pf_action_guard_options)
      end

      test 'a later declaration can change the resource and switch REST actions back on' do
        controller = Class.new(::ApplicationController) do
          include GUARD

          permission_forge_actions resource: 'Customer', rest_actions: false
          permission_forge_actions resource: 'Supplier', rest_actions: true
        end

        assert_equal({ resource: 'Supplier', actions: {}, rest_actions: true }, controller.pf_action_guard_options)
      end

      test 'a controller that skips the guard callback outright is not guarded' do
        guarded = Class.new(::ApplicationController) { include GUARD }
        partly = Class.new(guarded) { skip_before_action :pf_authorize_action!, only: :index }
        skipped = Class.new(guarded) { skip_before_action :pf_authorize_action! }

        assert PermissionForge::ControllerActions.guarded?(guarded)
        assert PermissionForge::ControllerActions.guarded?(partly)
        assert_not PermissionForge::ControllerActions.guarded?(skipped)
        assert_not PermissionForge::ControllerActions.guarded?(::ReportsController)
        assert_not PermissionForge::ControllerActions.guarded?(nil)
      end

      test 'guarded? refuses to guess when the controller has no before_action chain to read' do
        unreadable = Class.new { def self.pf_action_guard_options = {} }

        error = assert_raises(PermissionForge::ConfigurationError) { PermissionForge::ControllerActions.guarded?(unreadable) }
        assert_includes error.message, '_process_action_callbacks'
      end

      test 'a guard included in a base controller is inherited with its own declaration per subclass' do
        base = Class.new(::ApplicationController) { include GUARD }
        declared = Class.new(base) { permission_forge_actions resource: 'Supplier' }
        plain = Class.new(base)

        assert_equal 'Supplier', declared.pf_action_guard_options[:resource]
        assert_same PermissionForge::ControllerActions::EMPTY_OPTIONS, plain.pf_action_guard_options
        assert_same PermissionForge::ControllerActions::EMPTY_OPTIONS, base.pf_action_guard_options
      end

      test 'only guarded controllers expose the declaration' do
        assert_respond_to ::CustomersController, :pf_action_guard_options
        assert_respond_to ::Customers::MergesController, :pf_action_guard_options
        assert_not_respond_to ::ReportsController, :pf_action_guard_options
        assert_not_respond_to ::ApplicationController, :pf_action_guard_options
      end

      # --- what the concern adds to a controller ----------------------------------

      test 'the guard adds no routable action' do
        assert_equal %w[archive export index show], ::CustomersController.action_methods.to_a.sort
        assert_equal %w[create], ::Customers::MergesController.action_methods.to_a.sort
        assert_not_respond_to ::CustomersController.new, :pf_action_guard_options
        assert_not_respond_to ::CustomersController.new, :pf_action_guard_options=
        assert_includes ::CustomersController.private_instance_methods, :pf_authorize_action!
      end

      test 'the check runs as a before_action' do
        filters = ::CustomersController._process_action_callbacks.select { |callback| callback.kind == :before }

        assert_includes filters.map(&:filter), :pf_authorize_action!
        assert_not_includes ::ReportsController._process_action_callbacks.map(&:filter), :pf_authorize_action!
      end

      # --- the check --------------------------------------------------------------

      test 'an allowed action passes without rendering' do
        controller = controller_for(::CustomersController, 'index')

        assert_nil controller.send(:pf_authorize_action!)
        assert_nil controller.response_body
      end

      test 'a denied action raises with the resource, the action key and the controller' do
        controller = controller_for(::CustomersController, 'destroy')

        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { controller.send(:pf_authorize_action!) }

        assert_equal 'Customer', error.resource
        assert_equal 'destroy', error.action
        assert_equal 'customers', error.controller_path
        assert_equal :crud_denied, error.reason
        assert_nil controller.response_body
      end

      test 'the declared key is the one checked and reported' do
        action = create_resource_action(resource: @resource, name: 'merge', is_permitted: false)

        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize(::Customers::MergesController, 'create') }
        assert_equal %w[Customer merge customers/merges], [error.resource, error.action, error.controller_path]

        action.update!(is_permitted: true)

        assert_nil authorize(::Customers::MergesController, 'create')
      end

      test 'a subclass is checked with the inherited declaration' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)
        subclass = Class.new(::Customers::MergesController)

        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize(subclass, 'create') }

        assert_equal 'merge', error.action
      end

      test 'the guard follows unconfigured_action_strategy' do
        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize(::CustomersController, 'archive') }
        assert_equal :action_not_managed_blocked, error.reason, 'refused by default'

        PermissionForge.configuration.unconfigured_action_strategy = :allow

        assert_nil authorize(::CustomersController, 'archive')
      end

      test 'the guard follows nil_user_strategy' do
        Current.user = nil

        assert_nil authorize(::CustomersController, 'destroy')

        PermissionForge.configuration.nil_user_strategy = :deny

        error = assert_raises(PermissionForge::ActionNotAuthorizedError) { authorize(::CustomersController, 'index') }
        assert_equal :nil_user_denied, error.reason, 'a handler can tell "not signed in" from a denial'
      end

      test 'the bypass lambda receives the user and the controller instance' do
        received = nil
        PermissionForge.configuration.action_guard_bypass = lambda do |user, controller|
          received = [user, controller]
          true
        end
        controller = controller_for(::CustomersController, 'destroy')

        assert_nil controller.send(:pf_authorize_action!)
        assert_equal [@user, controller], received
      end
    end
  end
end
