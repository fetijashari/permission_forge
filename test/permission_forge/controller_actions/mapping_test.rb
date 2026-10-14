require 'test_helper'

module PermissionForge
  module ControllerActions
    class MappingTest < ActiveSupport::TestCase
      # Stands in for a controller that declared permission_forge_actions.
      def declaring(**)
        normalized = PermissionForge::ControllerActions.normalize_options(**)
        Class.new { define_singleton_method(:pf_action_guard_options) { normalized } }
      end

      def map(path, action, controller_class: nil)
        Mapping.call(controller_path: path, action_name: action, controller_class: controller_class)
      end

      # --- convention -----------------------------------------------------------

      test 'custom action maps to the controller model by convention' do
        target = map('customers', 'export')

        assert_equal 'Customer', target.resource
        assert_equal 'export', target.action
        assert_nil target.crud
        assert_not target.crud?
        assert_equal 'export', target.permission
      end

      test 'REST actions map to CRUD permissions' do
        expected = { 'index' => :read, 'show' => :read, 'new' => :create, 'create' => :create,
                     'edit' => :edit, 'update' => :edit, 'destroy' => :delete }

        expected.each do |action, crud|
          target = map('customers', action)

          assert_equal crud, target.crud, action
          assert_equal crud, target.permission, action
          assert_equal action, target.action
        end
      end

      test 'an action named after a can? CRUD word means that CRUD permission' do
        assert_equal :delete, map('customers', 'delete').crud
        assert_equal :read, map('customers', 'read').crud
      end

      test 'namespaced controller falls back to the last path segment' do
        assert_equal 'Customer', map('api/v1/customers', 'export').resource
      end

      test 'controller with no matching model is unmapped' do
        assert_nil map('reports', 'index')
        assert_nil map('customers/merges', 'create')
      end

      # Returning nil here would let the action through under :block.
      test 'action names outside the key format stay mapped but are not manageable' do
        ['exportCSV', 'export!', "export\nindex", 'a' * 64].each do |action|
          target = map('customers', action)

          assert_equal 'Customer', target.resource, action
          assert_equal action, target.action
          assert_nil target.crud
          assert_not target.manageable?, action
        end
      end

      test 'CRUD and well-formed custom actions are manageable' do
        assert_predicate map('customers', 'index'), :manageable?
        assert_predicate map('customers', 'export'), :manageable?
      end

      # --- exclusions -----------------------------------------------------------

      test 'engine and Rails-internal controllers are excluded' do
        assert_nil map('permission_forge/home', 'index')
        assert_nil map('permission_forge', 'index')
        assert_nil map('rails/health', 'show')
        assert_nil map('active_storage/blobs', 'show')
      end

      test 'a blank exclusion entry does not exclude everything' do
        [[nil], [''], ['/'], [nil, '']].each do |patterns|
          PermissionForge.configuration.controller_discovery_exclude = patterns

          assert_equal 'Customer', map('customers', 'export')&.resource, patterns.inspect
        end
      end

      test 'a string exclusion matches a controller or a namespace, not a name prefix' do
        PermissionForge.configuration.controller_discovery_exclude = %w[custom api/v1]

        assert_equal 'Customer', map('customers', 'export')&.resource
        assert_nil map('api/v1/customers', 'export')
        assert_nil map('api/v1', 'export')
        assert_equal 'Customer', map('api/v10/customers', 'export')&.resource
      end

      test 'configured exclusions accept regexps and string prefixes' do
        PermissionForge.configuration.controller_discovery_exclude = ['api/', /\Acustomers\z/]

        assert_nil map('api/v1/customers', 'export')
        assert_nil map('customers', 'export')
      end

      test 'the engine stays excluded when the host clears the exclusion list' do
        PermissionForge.configuration.controller_discovery_exclude = []

        assert_nil map('permission_forge/home', 'index')
        assert_equal 'Customer', map('customers', 'export').resource
      end

      # --- config resolver ------------------------------------------------------

      test 'resolver maps a nested controller to a resource and key' do
        PermissionForge.configuration.controller_action_resolver = lambda do |path, action|
          %w[Customer merge] if path == 'customers/merges' && action == 'create'
        end

        target = map('customers/merges', 'create')

        assert_equal 'Customer', target.resource
        assert_equal 'merge', target.action
        assert_nil target.crud
      end

      test 'resolver returning nil falls back to the convention' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) {}

        assert_equal 'Customer', map('customers', 'export').resource
      end

      test 'resolver returning false leaves the action unmanaged' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, action) { false if action == 'export' }

        assert_nil map('customers', 'export')
        assert_equal 'Customer', map('customers', 'archive').resource
      end

      test 'resolver may supply only the resource or only the key' do
        PermissionForge.configuration.controller_action_resolver = lambda do |path, _action|
          path == 'reports' ? ['Customer', nil] : [nil, 'send_out']
        end

        assert_equal %w[Customer index], map('reports', 'index').to_a.first(2)
        assert_equal %w[Customer send_out], map('customers', 'export').to_a.first(2)
      end

      test 'resolver key that is a CRUD word is checked as CRUD' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Customer edit] }

        assert_equal :edit, map('customers', 'archive').crud
      end

      # A typo must not turn into "unmapped", which the guard allows.
      test 'resolver answers outside the resource or key format raise' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[customer export] }
        error = assert_raises(PermissionForge::ConfigurationError) { map('customers', 'export') }
        assert_includes error.message, 'customers#export'
        assert_includes error.message, '"customer"'

        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { ['Customer', 'Not A Key'] }
        assert_raises(PermissionForge::ConfigurationError) { map('customers', 'export') }
      end

      test 'a resolver answer of the wrong shape raises instead of being ignored' do
        ['Customer', { resource: 'Customer', action: 'export' }, true, :Customer].each do |answer|
          PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { answer }

          error = assert_raises(PermissionForge::ConfigurationError, answer.inspect) { map('reports', 'index') }
          assert_includes error.message, 'must return [resource, key], false or nil'
        end
      end

      # Swallowing the error would make the controller "unmapped", which the
      # guard allows even under :block.
      test 'a model that fails to load raises instead of unmapping its controller' do
        file = Tempfile.new(['pf_boom_model', '.rb'])
        file.write("raise 'model failed to load'")
        file.close
        Object.autoload(:PfBoomModel, file.path)

        error = assert_raises(RuntimeError) { map('pf_boom_models', 'index') }
        assert_equal 'model failed to load', error.message
      ensure
        Object.send(:remove_const, :PfBoomModel) if Object.autoload?(:PfBoomModel) || Object.const_defined?(:PfBoomModel)
        file&.unlink
      end

      test 'a declaration is validated when it is made, not on every request' do
        assert_raises(ArgumentError) { declaring(resource: 'customer') }
        assert_raises(ArgumentError) { declaring(actions: { export: 'Bad Key' }) }
      end

      test 'the convention can be memoized by a caller that maps many actions' do
        conventions = {}

        2.times do
          target = Mapping.call(controller_path: 'api/v1/customers', action_name: 'export', conventions: conventions)
          assert_equal 'Customer', target.resource
        end
        assert_nil Mapping.call(controller_path: 'reports', action_name: 'index', conventions: conventions)

        assert_equal({ 'api/v1/customers' => 'Customer', 'reports' => nil }, conventions)
      end

      test 'the CRUD keys are the words can? answers from the CRUD flags' do
        assert_equal({ 'read' => :read, 'create' => :create, 'edit' => :edit, 'update' => :edit,
                       'delete' => :delete, 'destroy' => :delete }, PermissionForge::ControllerActions::CRUD_KEYS)
      end

      test 'a raising resolver propagates instead of failing open' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { raise ArgumentError, 'boom' }

        assert_raises(ArgumentError) { map('customers', 'export') }
      end

      # --- controller declaration -----------------------------------------------

      test 'controller declaration wins over the resolver and the convention' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Supplier other] }
        controller = declaring(resource: 'Customer', actions: { create: :merge })

        target = map('customers/merges', 'create', controller_class: controller)

        assert_equal 'Customer', target.resource
        assert_equal 'merge', target.action
        assert_nil target.crud
      end

      test 'declared resource accepts a class' do
        target = map('reports', 'index', controller_class: declaring(resource: ::Customer))

        assert_equal 'Customer', target.resource
        assert_equal :read, target.crud
      end

      test 'declared key that is a CRUD word gates a custom action by that flag' do
        target = map('customers', 'archive', controller_class: declaring(actions: { archive: :edit }))

        assert_equal :edit, target.crud
        assert_equal :edit, target.permission
      end

      test 'rest_actions: false leaves REST actions unmanaged but keeps custom ones' do
        controller = declaring(rest_actions: false, actions: { create: :merge })

        assert_nil map('customers', 'index', controller_class: controller)
        assert_equal 'export', map('customers', 'export', controller_class: controller).action
        assert_equal 'merge', map('customers', 'create', controller_class: controller).action
      end

      test 'a controller without a declaration uses the defaults' do
        assert_equal 'Customer', map('customers', 'export', controller_class: Class.new).resource
      end
    end
  end
end
