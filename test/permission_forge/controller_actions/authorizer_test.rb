require 'test_helper'

module PermissionForge
  module ControllerActions
    class AuthorizerTest < ActiveSupport::TestCase
      STRATEGIES = %i[allow block].freeze
      UNKNOWN_STRATEGIES = [:permit, :warn, :deny, 'ALLOW', nil, true].freeze

      # Records every lookup, so tests can assert what a decision cost.
      class SpyIndex
        attr_reader :calls

        def initialize(managed = {})
          @managed = managed
          @calls = []
        end

        def managed_actions(resource)
          @calls << resource.to_s
          @managed[resource.to_s]
        end
      end

      setup do
        @user = create_user
        @set = create_permission_set(name: 'Granting')
        @resource = create_resource(permission_set: @set, name: 'Customer', read_access: true)
        create_permission_set_user(user: @user, permission_set: @set)
      end

      def decide(path, action, user: @user, **)
        Authorizer.call(controller_path: path, action_name: action, user: user, **)
      end

      def assert_allowed(reason, decision)
        assert_equal reason, decision.reason
        assert_equal true, decision.allowed
        assert_predicate decision, :allowed?
        assert_not_predicate decision, :denied?
      end

      def assert_denied(reason, decision)
        assert_equal reason, decision.reason
        assert_equal false, decision.allowed
        assert_not_predicate decision, :allowed?
        assert_predicate decision, :denied?
        assert_not_nil decision.target, 'a denied decision names what was checked'
      end

      def with_strategy(value)
        PermissionForge.configuration.unconfigured_action_strategy = value
        yield
      end

      def each_strategy(&block)
        STRATEGIES.each { |strategy| with_strategy(strategy) { block.call(strategy) } }
      end

      def bypass_with(&block)
        PermissionForge.configuration.action_guard_bypass = block
      end

      # Stands in for a controller that declared permission_forge_actions.
      def declaring(**)
        normalized = PermissionForge::ControllerActions.normalize_options(**)
        Class.new { define_singleton_method(:pf_action_guard_options) { normalized } }
      end

      # A second set nobody in the test is assigned to.
      def other_set_with(action:, permitted: true, **set_attrs)
        other = create_permission_set({ name: 'Other' }.merge(set_attrs))
        resource = create_resource(permission_set: other, name: 'Customer', read_access: true, create_access: true)
        create_resource_action(resource: resource, name: action, is_permitted: permitted)
        other
      end

      # --- row 1: the action maps to no resource ---------------------------------

      test 'row 1: an action that maps to no resource is allowed under every strategy' do
        each_strategy do
          decision = decide('reports', 'index')

          assert_allowed :unmapped, decision
          assert_nil decision.target
        end
      end

      test 'row 1: excluded controllers and resolver-unmanaged actions are allowed' do
        with_strategy(:block) do
          assert_allowed :unmapped, decide('permission_forge/home', 'index')
          assert_allowed :unmapped, decide('rails/health', 'show')

          PermissionForge.configuration.controller_action_resolver = ->(_path, action) { false if action == 'export' }
          assert_allowed :unmapped, decide('customers', 'export')
        end
      end

      test 'row 1 comes before the user checks' do
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_allowed :unmapped, decide('reports', 'index', user: nil)
        assert_allowed :unmapped, decide('reports', 'index', user: Object.new)
      end

      test 'row 1 reads neither the index nor the bypass' do
        bypass_with { |_user, _controller| flunk('bypass must not run for an unmapped action') }
        index = SpyIndex.new

        assert_allowed :unmapped, decide('reports', 'index', index: index)
        assert_empty index.calls
      end

      test 'rest_actions: false leaves REST actions unchecked and keeps custom actions checked' do
        controller = declaring(rest_actions: false)
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        assert_denied :crud_denied, decide('customers', 'destroy')
        each_strategy do
          assert_allowed :unmapped, decide('customers', 'destroy', controller_class: controller)
          assert_allowed :unmapped, decide('customers', 'index', controller_class: controller)
          assert_denied :action_denied, decide('customers', 'export', controller_class: controller)
        end
      end

      test 'rest_actions: false still checks a REST action that the declaration lists' do
        controller = declaring(rest_actions: false, actions: { create: :merge })
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)

        decision = decide('customers', 'create', controller_class: controller)

        assert_denied :action_denied, decision
        assert_equal 'merge', decision.target.action
      end

      # --- row 2: no current user -------------------------------------------------

      test 'row 2: no user is allowed under nil_user_strategy :bypass' do
        PermissionForge.configuration.nil_user_strategy = :bypass

        each_strategy do
          assert_allowed :nil_user_bypassed, decide('customers', 'index', user: nil)
          assert_allowed :nil_user_bypassed, decide('customers', 'destroy', user: nil)
          assert_allowed :nil_user_bypassed, decide('suppliers', 'sync', user: nil)
        end
      end

      test 'row 2: no user is denied under every other nil_user_strategy' do
        [:deny, :raise, 'deny', 'raise'].each do |strategy|
          PermissionForge.configuration.nil_user_strategy = strategy

          each_strategy do
            assert_denied :nil_user_denied, decide('customers', 'index', user: nil)
            assert_denied :nil_user_denied, decide('suppliers', 'sync', user: nil)
          end
        end
      end

      test 'row 2: a false user counts as no user' do
        PermissionForge.configuration.nil_user_strategy = :deny

        assert_denied :nil_user_denied, decide('customers', 'index', user: false)
      end

      test 'row 2 comes before the bypass: the lambda never sees a missing user' do
        PermissionForge.configuration.nil_user_strategy = :deny
        bypass_with { |_user, _controller| flunk('bypass must not run without a user') }

        assert_denied :nil_user_denied, decide('customers', 'index', user: nil)
      end

      test 'the user defaults to PermissionForge.current_user' do
        PermissionForge.configuration.nil_user_strategy = :deny

        Current.user = @user
        assert_allowed :crud_granted, Authorizer.call(controller_path: 'customers', action_name: 'index')

        Current.user = nil
        assert_denied :nil_user_denied, Authorizer.call(controller_path: 'customers', action_name: 'index')
      end

      # --- row 3: action_guard_bypass --------------------------------------------

      test 'row 3: a bypass returning true allows what the permission sets deny' do
        received = nil
        bypass_with do |user, controller|
          received = [user, controller]
          true
        end
        controller = Object.new

        each_strategy do
          assert_allowed :guard_bypassed, decide('customers', 'destroy', controller: controller)
          assert_equal [@user, controller], received
        end
      end

      test 'row 3 reads no index' do
        bypass_with { |_user, _controller| true }
        index = SpyIndex.new

        assert_allowed :guard_bypassed, decide('customers', 'destroy', index: index)
        assert_empty index.calls
      end

      test 'row 3: a bypass returning false leaves the decision to the permission sets' do
        bypass_with { |_user, _controller| false }

        assert_denied :crud_denied, decide('customers', 'destroy')
        assert_allowed :crud_granted, decide('customers', 'index')
      end

      test 'row 3: only an explicit true bypasses' do
        ['yes', 'true', 1, Object.new, nil].each do |value|
          bypass_with { |_user, _controller| value }

          assert_denied :crud_denied, decide('customers', 'destroy')
        end
      end

      test 'row 3: a raising bypass does not allow' do
        bypass_with { |_user, _controller| raise ArgumentError, 'boom' }

        assert_denied :crud_denied, decide('customers', 'destroy')
        with_strategy(:block) { assert_denied :resource_not_managed_blocked, decide('suppliers', 'index') }
      end

      test 'row 3: a raising bypass leaves granted actions granted' do
        bypass_with { |_user, _controller| raise ArgumentError, 'boom' }

        assert_allowed :crud_granted, decide('customers', 'index')
      end

      test 'row 3: a raising bypass is logged' do
        log = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(log)
        bypass_with { |_user, _controller| raise ArgumentError, 'boom' }

        decide('customers', 'destroy')

        assert_includes log.string, '[PermissionForge] action_guard_bypass error: ArgumentError: boom'
      ensure
        Rails.logger = original
      end

      test 'row 3: a bypass with the wrong arity or that is not callable does not allow' do
        PermissionForge.configuration.action_guard_bypass = ->(_user) { true }
        assert_denied :crud_denied, decide('customers', 'destroy')

        PermissionForge.configuration.action_guard_bypass = true
        assert_denied :crud_denied, decide('customers', 'destroy')
      end

      # --- a user object without can? --------------------------------------------

      test 'a user without can? is denied on a managed resource' do
        each_strategy do
          assert_denied :unsupported_user, decide('customers', 'index', user: Object.new)
          assert_denied :unsupported_user, decide('customers', 'export', user: Object.new)
        end
      end

      test 'a user without can? is denied on an unmanaged resource even under :allow' do
        each_strategy do
          assert_denied :unsupported_user, decide('suppliers', 'index', user: Object.new)
          assert_denied :unsupported_user, decide('suppliers', 'sync', user: Object.new)
        end
      end

      test 'a user without can? reads no index' do
        index = SpyIndex.new

        assert_denied :unsupported_user, decide('customers', 'index', user: Object.new, index: index)
        assert_empty index.calls
      end

      test 'a user without can? passes only through an explicit bypass' do
        outsider = Object.new
        bypass_with { |user, _controller| user.equal?(outsider) }

        assert_allowed :guard_bypassed, decide('customers', 'index', user: outsider)
        assert_denied :unsupported_user, decide('customers', 'index', user: Object.new)
      end

      test 'only an explicit true from can? grants' do
        truthy = Object.new
        truthy.define_singleton_method(:can?) { |_permission, _resource| 'yes' }

        assert_denied :crud_denied, decide('customers', 'index', user: truthy)
        assert_denied :action_not_managed_blocked, with_strategy(:block) { decide('customers', 'export', user: truthy) }
      end

      # --- row 4: the resource is not managed -------------------------------------

      test 'row 4: an unmanaged resource is allowed under :allow' do
        with_strategy(:allow) do
          assert_allowed :resource_not_managed, decide('suppliers', 'index')
          assert_allowed :resource_not_managed, decide('suppliers', 'destroy')
          assert_allowed :resource_not_managed, decide('suppliers', 'sync')
        end
      end

      test 'row 4: an unmanaged resource is denied under :block' do
        with_strategy(:block) do
          assert_denied :resource_not_managed_blocked, decide('suppliers', 'index')
          assert_denied :resource_not_managed_blocked, decide('suppliers', 'destroy')
          assert_denied :resource_not_managed_blocked, decide('suppliers', 'sync')
        end
      end

      test 'row 4: unknown strategy values are refused when set' do
        UNKNOWN_STRATEGIES.each do |strategy|
          assert_raises(PermissionForge::ConfigurationError, strategy.inspect) { with_strategy(strategy) { flunk } }
        end
      end

      test 'row 4: the strategy may be given as a string' do
        with_strategy('allow') { assert_allowed :resource_not_managed, decide('suppliers', 'index') }
        with_strategy('block') { assert_denied :resource_not_managed_blocked, decide('suppliers', 'index') }
      end

      test 'row 4: a resource only in an inactive set is not managed' do
        inactive_set = create_permission_set(name: 'Inactive', is_active: false)
        create_resource(permission_set: inactive_set, name: 'Supplier', read_access: true)
        create_permission_set_user(user: @user, permission_set: inactive_set)

        with_strategy(:allow) { assert_allowed :resource_not_managed, decide('suppliers', 'index') }
        with_strategy(:block) { assert_denied :resource_not_managed_blocked, decide('suppliers', 'index') }
      end

      test 'row 4: an inactive resource is not managed' do
        create_resource(permission_set: @set, name: 'Supplier', read_access: true, is_active: false)

        with_strategy(:allow) { assert_allowed :resource_not_managed, decide('suppliers', 'index') }
        with_strategy(:block) { assert_denied :resource_not_managed_blocked, decide('suppliers', 'index') }
      end

      test 'row 4 costs one index read' do
        index = SpyIndex.new

        assert_allowed :resource_not_managed, decide('suppliers', 'sync', index: index)
        assert_equal ['Supplier'], index.calls
      end

      # --- row 5: CRUD targets ----------------------------------------------------

      test 'row 5: a REST action follows its CRUD flag under every strategy' do
        @resource.update!(edit_access: true)
        expected = { 'index' => true, 'show' => true, 'edit' => true, 'update' => true,
                     'new' => false, 'create' => false, 'destroy' => false }

        each_strategy do
          expected.each do |action, granted|
            decision = decide('customers', action)

            assert_equal granted, decision.allowed?, action
            assert_equal (granted ? :crud_granted : :crud_denied), decision.reason, action
            assert_equal 'Customer', decision.target.resource
          end
        end
      end

      test 'row 5: a resource managed by a set the user is not in is denied' do
        outsider = create_user

        each_strategy do
          assert_denied :crud_denied, decide('customers', 'index', user: outsider)
          assert_denied :crud_denied, decide('api/v1/customers', 'show', user: outsider)
        end
      end

      test 'row 5: a muting set takes the CRUD permission away' do
        muting = create_permission_set(name: 'Muting', is_muting: true)
        create_resource(permission_set: muting, name: 'Customer', read_access: true)

        assert_allowed :crud_granted, decide('customers', 'index')

        create_permission_set_user(user: @user, permission_set: muting)

        each_strategy { assert_denied :crud_denied, decide('customers', 'index') }
      end

      test 'row 5: a resource managed only by a muting set denies everyone' do
        muting = create_permission_set(name: 'Muting', is_muting: true)
        create_resource(permission_set: muting, name: 'Supplier', read_access: true)

        each_strategy { assert_denied :crud_denied, decide('suppliers', 'index') }
      end

      test 'row 5: an inactive assignment set grants nothing while another set manages the resource' do
        outsider = create_user
        inactive_set = create_permission_set(name: 'Inactive', is_active: false)
        create_resource(permission_set: inactive_set, name: 'Customer', read_access: true)
        create_permission_set_user(user: outsider, permission_set: inactive_set)

        each_strategy { assert_denied :crud_denied, decide('customers', 'index', user: outsider) }
      end

      test 'row 5: a declared CRUD word gates a custom action by that flag' do
        controller = declaring(actions: { archive: :edit })

        assert_denied :crud_denied, decide('customers', 'archive', controller_class: controller)

        @resource.update!(edit_access: true)

        assert_allowed :crud_granted, decide('customers', 'archive', controller_class: controller)
      end

      test 'row 5: a granted CRUD action never reads the index' do
        index = SpyIndex.new('Customer' => [])

        assert_allowed :crud_granted, decide('customers', 'index', index: index)
        assert_empty index.calls
      end

      test 'row 5: a denied CRUD action costs one index read' do
        index = SpyIndex.new('Customer' => [])

        assert_denied :crud_denied, decide('customers', 'destroy', index: index)
        assert_equal ['Customer'], index.calls
      end

      # --- row 6: custom action, granted ------------------------------------------

      test 'row 6: a permitted custom action is allowed under every strategy' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)

        each_strategy do
          decision = decide('customers', 'export')

          assert_allowed :action_granted, decision
          assert_equal 'export', decision.target.action
          assert_nil decision.target.crud
        end
      end

      test 'row 6: a granted custom action never reads the index' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        index = SpyIndex.new('Customer' => ['export'])

        assert_allowed :action_granted, decide('customers', 'export', index: index)
        assert_empty index.calls
      end

      test 'row 7 costs one index read' do
        index = SpyIndex.new('Customer' => ['export'])

        assert_denied :action_denied, decide('customers', 'export', index: index)
        assert_equal ['Customer'], index.calls
      end

      test 'row 6: one granting set is enough when another set does not permit the action' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        other = other_set_with(action: 'export', permitted: false)
        create_permission_set_user(user: @user, permission_set: other)

        assert_allowed :action_granted, decide('customers', 'export')
      end

      # --- row 7: custom action, managed but not granted --------------------------

      test 'row 7: a listed action that is not permitted is denied under every strategy' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        each_strategy { assert_denied :action_denied, decide('customers', 'export') }
      end

      test 'row 7: an action permitted only in a set the user is not in is denied' do
        other_set_with(action: 'export', permitted: true)

        each_strategy { assert_denied :action_denied, decide('customers', 'export') }
      end

      test 'row 7: a muting set takes a granted action away' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true)
        muting = other_set_with(action: 'export', permitted: true, name: 'Muting', is_muting: true)

        assert_allowed :action_granted, decide('customers', 'export')

        create_permission_set_user(user: @user, permission_set: muting)

        each_strategy { assert_denied :action_denied, decide('customers', 'export') }
      end

      test 'row 7: an action listed only by a muting set is managed, so it is denied' do
        other_set_with(action: 'export', permitted: true, name: 'Muting', is_muting: true)

        each_strategy { assert_denied :action_denied, decide('customers', 'export') }
      end

      test 'row 7: an expired assignment no longer grants a managed action' do
        other = other_set_with(action: 'export', permitted: true)
        assignment = create_permission_set_user(user: @user, permission_set: other, expires_at: 1.hour.from_now)

        assert_allowed :action_granted, decide('customers', 'export')

        assignment.update_columns(expires_at: 1.hour.ago)
        @user.invalidate_permissions

        each_strategy { assert_denied :action_denied, decide('customers', 'export') }
      end

      # --- row 8: custom action, not managed --------------------------------------

      test 'row 8: an action nobody lists is allowed under :allow' do
        with_strategy(:allow) do
          decision = decide('customers', 'archive')

          assert_allowed :action_not_managed, decision
          assert_equal 'archive', decision.target.action
        end
      end

      test 'row 8: an action nobody lists is denied under :block' do
        with_strategy(:block) { assert_denied :action_not_managed_blocked, decide('customers', 'archive') }
      end

      test 'row 8: an action nobody lists is denied under the String "block"' do
        with_strategy('block') { assert_denied :action_not_managed_blocked, decide('customers', 'archive') }
      end

      test 'row 8: an inactive action row neither manages nor grants' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: true, is_active: false)

        with_strategy(:allow) { assert_allowed :action_not_managed, decide('customers', 'export') }
        with_strategy(:block) { assert_denied :action_not_managed_blocked, decide('customers', 'export') }
      end

      test 'row 8: an action listed only in an inactive set or on an inactive resource is not managed' do
        other_set_with(action: 'export', permitted: true, name: 'Inactive', is_active: false)
        inactive_resource = create_resource(permission_set: create_permission_set(name: 'Third'), name: 'Customer',
                                            is_active: false)
        create_resource_action(resource: inactive_resource, name: 'archive', is_permitted: true)

        with_strategy(:allow) do
          assert_allowed :action_not_managed, decide('customers', 'export')
          assert_allowed :action_not_managed, decide('customers', 'archive')
        end
        with_strategy(:block) do
          assert_denied :action_not_managed_blocked, decide('customers', 'export')
          assert_denied :action_not_managed_blocked, decide('customers', 'archive')
        end
      end

      test 'an action whose name cannot be a key follows the strategy instead of slipping through' do
        with_strategy(:allow) { assert_allowed :action_not_managed, decide('customers', 'exportCSV') }
        with_strategy(:block) { assert_denied :action_not_managed_blocked, decide('customers', 'exportCSV') }
      end

      test 'a resolver typo surfaces as a configuration error, never as an allow' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[customer export] }

        each_strategy do
          assert_raises(PermissionForge::ConfigurationError) { decide('customers', 'export') }
        end
      end

      test 'row 8 costs one index read' do
        index = SpyIndex.new('Customer' => [])

        assert_allowed :action_not_managed, decide('customers', 'archive', index: index)
        assert_equal ['Customer'], index.calls
      end

      test 'the first row for an action makes it managed for everyone' do
        assert_allowed :action_not_managed, decide('customers', 'archive')

        other_set_with(action: 'archive', permitted: true)

        assert_denied :action_denied, decide('customers', 'archive')
      end

      # --- mapping through the controller ----------------------------------------

      test 'a declared action key is what gets checked' do
        controller = declaring(resource: 'Customer', actions: { create: :merge })
        create_resource_action(resource: @resource, name: 'merge', is_permitted: true)

        decision = decide('customers/merges', 'create', controller_class: controller)

        assert_allowed :action_granted, decision
        assert_equal %w[Customer merge], [decision.target.resource, decision.target.action]
      end

      test 'the controller class defaults to the class of the controller instance' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)

        decision = decide('anything', 'create', controller: ::Customers::MergesController.new)

        assert_denied :action_denied, decision
        assert_equal 'merge', decision.target.action
      end

      test 'the controller class defaults to the one the path names' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)

        decision = decide('customers/merges', 'create')

        assert_denied :action_denied, decision
        assert_equal %w[Customer merge], [decision.target.resource, decision.target.action]
        assert_allowed :unmapped, decide('no/such/things', 'create')
      end

      test 'a subclass inherits the declaration of its controller' do
        create_resource_action(resource: @resource, name: 'merge', is_permitted: false)
        subclass = Class.new(::Customers::MergesController)

        decision = decide('admin/merges', 'create', controller_class: subclass)

        assert_denied :action_denied, decision
        assert_equal 'merge', decision.target.action
      end

      test 'a raising resolver propagates instead of allowing' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { raise ArgumentError, 'boom' }

        assert_raises(ArgumentError) { decide('customers', 'export') }
      end

      # --- injected dependencies --------------------------------------------------

      test 'configuration is injectable' do
        configuration = PermissionForge::Configuration.new
        configuration.unconfigured_action_strategy = :block
        configuration.nil_user_strategy = :deny

        assert_denied :action_not_managed_blocked, decide('customers', 'archive', configuration: configuration)
        assert_denied :nil_user_denied, decide('customers', 'index', user: nil, configuration: configuration)
        assert_allowed :action_not_managed, decide('customers', 'archive')
      end

      test 'unknown keywords are rejected' do
        assert_raises(ArgumentError) { decide('customers', 'index', usr: @user) }
      end

      # --- allowed? and the Decision ----------------------------------------------

      test 'allowed? answers with a boolean using the same logic' do
        create_resource_action(resource: @resource, name: 'export', is_permitted: false)

        assert_equal true, Authorizer.allowed?(controller_path: 'customers', action_name: 'index', user: @user)
        assert_equal false, Authorizer.allowed?(controller_path: 'customers', action_name: :export, user: @user)
        assert_equal true, Authorizer.allowed?(controller_path: 'reports', action_name: 'index', user: @user)

        Current.user = @user
        assert_equal false, Authorizer.allowed?(controller_path: 'customers', action_name: 'destroy')
      end

      test 'every reason says whether it allows' do
        allowing = %i[unmapped nil_user_bypassed guard_bypassed resource_not_managed crud_granted action_granted
                      action_not_managed]
        denying = %i[nil_user_denied unsupported_user resource_not_managed_blocked crud_denied action_denied
                     action_not_managed_blocked]

        assert_equal allowing.sort, Authorizer::REASONS.select { |_reason, allowed| allowed == true }.keys.sort
        assert_equal denying.sort, Authorizer::REASONS.select { |_reason, allowed| allowed == false }.keys.sort
        assert_predicate Authorizer::REASONS, :frozen?
      end
    end
  end
end
