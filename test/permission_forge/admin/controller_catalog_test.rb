require_relative 'action_catalog_support'

module PermissionForge
  module Admin
    # The stand-in controllers (PfStubGuardedController, PfStubPlainController,
    # PfStubSkippingController) come from action_catalog_support.
    class ControllerCatalogTest < ActiveSupport::TestCase
      MERGE_RESOLVER = ->(path, _action) { %w[Customer merge] if path == 'customers/merges' }

      def catalog(routes = Rails.application.routes)
        ControllerCatalog.new(routes: routes)
      end

      def draw(&)
        ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&) }
      end

      def entry(catalog, endpoint)
        catalog.entries.find { |e| e.endpoint == endpoint }
      end

      # --- the dummy app's routes -------------------------------------------------

      test 'lists the mapped controller actions of the app, sorted by resource and key' do
        PermissionForge.configuration.controller_action_resolver = MERGE_RESOLVER

        assert_equal %w[customers#archive customers#export customers#index customers/merges#create customers#show],
                     catalog.entries.map(&:endpoint)
      end

      test 'an entry carries verbs, paths, the resource and the action key' do
        export = entry(catalog, 'customers#export')

        assert_equal ['GET'], export.verbs
        assert_equal ['/customers/export'], export.paths
        assert_equal 'Customer', export.resource
        assert_equal 'export', export.key
        assert_nil export.crud
        assert_not export.crud?
      end

      test 'REST actions are listed as CRUD entries and left out of the custom list' do
        PermissionForge.configuration.controller_action_resolver = MERGE_RESOLVER
        index = entry(catalog, 'customers#index')

        assert_equal :read, index.crud
        assert_predicate index, :crud?
        assert_equal %w[archive export merge], catalog.for_resource('Customer').map(&:key)
        assert_equal %w[archive export merge], catalog.keys_for(:Customer)
      end

      test 'a nested controller is listed under the key the resolver gives it' do
        PermissionForge.configuration.controller_action_resolver = MERGE_RESOLVER
        merge = catalog.for_resource('Customer').last

        assert_equal 'customers/merges#create', merge.endpoint
        assert_equal ['/customers/:customer_id/merge'], merge.paths
        assert_equal ['POST'], merge.verbs
        assert_nil merge.crud
      end

      test 'controllers that map to no resource are not listed' do
        assert_nil entry(catalog, 'reports#index')
        assert_empty catalog.for_resource('Report')
        assert_empty catalog.keys_for('Supplier')
      end

      test 'the engine and its mount point are never listed' do
        assert(catalog.entries.none? { |e| e.controller_path.start_with?('permission_forge') })
      end

      test 'an action the resolver marks as never managed is not listed' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, action) { false if action == 'archive' }

        assert_nil entry(catalog, 'customers#archive')
        assert_includes catalog.keys_for('Customer'), 'export'
      end

      test 'configured exclusions drop a controller' do
        PermissionForge.configuration.controller_discovery_exclude = ['customers']

        assert_empty catalog.entries
      end

      test 'an action whose name cannot be a ResourceAction key is not offered' do
        routes = draw do
          get 'customers/export', to: 'customers#export'
          get 'customers/export_csv', to: 'customers#exportCSV'
        end

        assert_equal ['export'], catalog(routes).keys_for('Customer')
        assert_nil entry(catalog(routes), 'customers#exportCSV')
      end

      # The guard checks it all the same, so the audit lists it among the
      # actions no Permission Set manages (it never can, without a key).
      test 'an action whose name cannot be a key is still among the mapped entries' do
        routes = draw do
          get 'customers/export', to: 'customers#export'
          get 'customers/export_csv', to: 'customers#exportCSV'
        end
        mapped = catalog(routes).mapped_entries

        assert_equal %w[customers#export customers#exportCSV], mapped.map(&:endpoint)
        assert_equal [true, false], mapped.map(&:manageable?)
        assert_equal [true, true], mapped.map(&:guarded?)
      end

      test 'a resolver typo drops that entry and is logged, never listed under a wrong name' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, action) { %w[customer export] if action == 'export' }

        assert_nil entry(catalog, 'customers#export')
        assert_includes catalog.keys_for('Customer'), 'archive'
      end

      # --- an injected route set --------------------------------------------------

      test 'verbs and paths are merged per controller action' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { ['Customer', nil] }
        routes = draw do
          resources :pf_stub_plain, only: :update
          match 'plain/export', to: 'pf_stub_plain#export', via: %i[get post]
          get 'exports/plain', to: 'pf_stub_plain#export'
          match 'plain/ping', to: 'pf_stub_plain#ping', via: :all
        end
        found = catalog(routes)
        update = entry(found, 'pf_stub_plain#update')
        export = entry(found, 'pf_stub_plain#export')

        assert_equal %w[PATCH PUT], update.verbs
        assert_equal ['/pf_stub_plain/:id'], update.paths
        assert_equal :edit, update.crud
        assert_equal %w[GET POST], export.verbs
        assert_equal ['/exports/plain', '/plain/export'], export.paths
        assert_equal [ControllerCatalog::ANY_VERB], entry(found, 'pf_stub_plain#ping').verbs
        assert_equal %w[export ping], found.keys_for('Customer')
      end

      test 'routes without a static controller and action are skipped' do
        routes = draw do
          get 'old', to: redirect('/customers')
          mount ->(_env) { [200, {}, ['ok']] }, at: '/rack'
          get 'customers/export', controller: :customers, action: :export
        end

        assert_equal ['customers#export'], catalog(routes).entries.map(&:endpoint)
      end

      test 'internal routes are skipped' do
        routes = draw { get 'customers/export', to: 'customers#export', internal: true }

        assert_empty catalog(routes).entries
      end

      test 'a controller is guarded when its class includes the guard' do
        PermissionForge.configuration.controller_action_resolver = lambda do |path, _action|
          %w[Customer poke] if path == 'pf_stub_plain'
        end
        routes = draw do
          post 'widgets/refresh', to: 'pf_stub_guarded#refresh'
          get 'plain', to: 'pf_stub_plain#poke'
        end
        found = catalog(routes)
        refresh = entry(found, 'pf_stub_guarded#refresh')

        assert_predicate refresh, :guarded?
        assert_equal %w[Customer sync], [refresh.resource, refresh.key]
        assert_not entry(found, 'pf_stub_plain#poke').guarded?
        assert_predicate found, :any_guarded?
        assert_equal %w[poke sync], found.keys_for('Customer')
      end

      test 'a controller that includes the guard and skips it for every action is not guarded' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Customer poke] }
        found = catalog(draw { get 'skipping', to: 'pf_stub_skipping#poke' })

        assert_equal ['pf_stub_skipping#poke'], found.entries.map(&:endpoint)
        assert_not found.entries.first.guarded?
        assert_not found.any_guarded?
      end

      test 'the guard status is the one ControllerActions.guarded? gives' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Customer poke] }
        routes = draw do
          get 'guarded', to: 'pf_stub_guarded#poke'
          get 'plain', to: 'pf_stub_plain#poke'
          get 'skipping', to: 'pf_stub_skipping#poke'
        end

        catalog(routes).entries.each do |found|
          klass = PermissionForge::ControllerActions.controller_class_for(found.controller_path)

          assert_equal PermissionForge::ControllerActions.guarded?(klass), found.guarded?, found.endpoint
        end
      end

      test 'any_guarded? is false while no listed controller includes the guard' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Customer poke] }
        found = catalog(draw { get 'plain', to: 'pf_stub_plain#poke' })

        assert_equal ['pf_stub_plain#poke'], found.entries.map(&:endpoint)
        assert_not found.any_guarded?
      end

      test 'a controller class that does not exist is still mapped, unguarded' do
        PermissionForge.configuration.controller_action_resolver = ->(_path, _action) { %w[Customer ghost] }
        found = catalog(draw { get 'ghost', to: 'pf_stub_no_such#index' })

        assert_equal ['ghost'], found.keys_for('Customer')
        assert_not found.entries.first.guarded?
      end

      # --- failures stay local ----------------------------------------------------

      test 'a raising resolver drops that entry, not the catalog' do
        PermissionForge.configuration.controller_action_resolver = lambda do |path, _action|
          raise 'resolver exploded' if path == 'reports'
        end

        assert_empty %w[archive export] - catalog.keys_for('Customer')
        assert_nil entry(catalog, 'reports#index')
      end

      test 'what the catalog could not judge is kept in skipped' do
        PermissionForge.configuration.controller_action_resolver = lambda do |_path, action|
          action == 'export' ? raise(ArgumentError, 'boom') : nil
        end
        found = catalog

        assert_equal ['customers#export: ArgumentError'], found.skipped
        assert_not_includes found.mapped_entries.map(&:endpoint), 'customers#export'
        assert_predicate found.skipped, :frozen?
      end

      test 'a controller that fails to load is listed without its class' do
        Object.autoload(:PfStubBrokenController, File.join(Dir.tmpdir, 'pf_stub_missing_controller.rb'))
        PermissionForge.configuration.controller_action_resolver = lambda do |path, _action|
          path == 'pf_stub_broken' ? %w[Customer broken] : %w[Customer poke]
        end
        routes = draw do
          get 'broken', to: 'pf_stub_broken#index'
          get 'plain', to: 'pf_stub_plain#poke'
        end
        found = catalog(routes)

        assert_equal %w[broken poke], found.keys_for('Customer')
        assert_not entry(found, 'pf_stub_broken#index').guarded?
        assert_equal 1, found.skipped.size
        assert_match(/\Apf_stub_broken: /, found.skipped.first)
      ensure
        Object.send(:remove_const, :PfStubBrokenController) if Object.autoload?(:PfStubBrokenController)
      end

      test 'the controller-name convention is resolved once per controller, not once per route' do
        routes = draw do
          get 'customers/export', to: 'customers#export'
          post 'customers/archive', to: 'customers#archive'
          get 'customers', to: 'customers#index'
          get 'reports', to: 'reports#index'
        end
        found = catalog(routes)
        conventions = found.instance_variable_get(:@conventions)

        assert_empty conventions
        assert_equal %w[customers#archive customers#export customers#index], found.entries.map(&:endpoint)
        assert_equal({ 'customers' => 'Customer', 'reports' => nil }, conventions)
      end

      test 'the route table is read once per instance' do
        routes = draw { get 'customers/export', to: 'customers#export' }
        found = catalog(routes)
        first = found.entries
        routes.draw { get 'customers/archive', to: 'customers#archive' }

        assert_same first, found.entries
        assert_predicate first, :frozen?
        assert_equal ['customers#archive'], catalog(routes).entries.map(&:endpoint)
      end
    end
  end
end
