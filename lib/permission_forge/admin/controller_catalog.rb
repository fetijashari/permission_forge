# frozen_string_literal: true

module PermissionForge
  module Admin
    # The host app's controller actions, resolved the way the runtime guard
    # resolves them (ControllerActions::Mapping) — so the admin lists exactly
    # what the guard checks.
    #
    # Reads the route table once per instance. Routes without a static
    # controller and action (mounted engines and Rack apps, redirects, dynamic
    # segments), internal routes, excluded controllers and actions whose name
    # cannot be a ResourceAction key are skipped. A
    # controller that fails to load, or a host resolver that raises, drops
    # that one entry instead of the whole catalog.
    #
    # @example
    #   catalog = ControllerCatalog.new
    #   catalog.keys_for('Customer')     # => ['archive', 'export']
    #   catalog.for_resource('Customer') # => [#<struct Entry controller_path="customers", action_name="archive", ...>]
    #   catalog.any_guarded?             # => true once a listed controller runs the guard
    class ControllerCatalog
      # Shown for a route that answers every HTTP verb.
      ANY_VERB = 'ANY'
      FORMAT_SUFFIX = '(.:format)'

      # One mapped controller action. `key` is the action key the guard asks
      # for; `crud` is :read / :create / :edit / :delete when the action means
      # a CRUD permission, nil for a custom action. `guarded` is whether the
      # controller runs the guard (ControllerActions.guarded?).
      Entry = Struct.new(:controller_path, :action_name, :verbs, :paths, :resource, :key, :crud, :guarded,
                         keyword_init: true) do
        def crud? = !crud.nil?
        def guarded? = guarded == true

        # 'customers#export'
        def endpoint = "#{controller_path}##{action_name}"

        # A custom (non-CRUD) action of the named resource.
        def custom_for?(resource_name) = resource == resource_name && !crud?

        def sort_key = [resource, key, controller_path, action_name]
      end

      # Reads one route: its static controller and action, verbs and path.
      class RoutedAction
        def initialize(route)
          @route = route
        end

        # @return [Array(String, String), nil] [controller_path, action_name];
        #   nil for an internal route or one without a static controller and
        #   action (mounted apps, redirects, dynamic segments)
        def target
          return nil if @route.respond_to?(:internal) && @route.internal

          parts = @route.defaults.values_at(:controller, :action)
          parts.map(&:to_s) if parts.all? { |part| part.is_a?(String) || part.is_a?(Symbol) }
        end

        def verbs
          verbs = @route.verb.to_s.split('|').reject(&:empty?)
          verbs.empty? ? [ANY_VERB] : verbs
        end

        def path
          @route.path.spec.to_s.delete_suffix(FORMAT_SUFFIX)
        end

        # Adds this route's verbs and path to its target's entry in `found`.
        def merge_into(found)
          merged = (found[target] ||= { verbs: [], paths: [] })
          merged[:verbs] |= verbs
          merged[:paths] |= [path]
        end
      end
      private_constant :RoutedAction

      def initialize(configuration: PermissionForge.configuration, routes: Rails.application.routes)
        @configuration = configuration
        @routes = routes
        @controller_classes = {}
        # controller_path => conventional resource, filled by Mapping: one
        # lookup per controller instead of one per route.
        @conventions = {}
      end

      # @return [Array<Entry>] one per mapped (controller_path, action_name),
      #   sorted by resource, key, controller and action
      def entries
        @entries ||= routed_actions.filter_map { |(path, action), route| build_entry(path, action, route) }
                                   .sort_by(&:sort_key).freeze
      end

      # @param resource_name [String, Symbol] e.g. 'Customer'
      # @return [Array<Entry>] the resource's custom (non-CRUD) entries, sorted by key
      def for_resource(resource_name)
        name = resource_name.to_s
        entries.select { |entry| entry.custom_for?(name) }
      end

      # @param resource_name [String, Symbol]
      # @return [Array<String>] unique custom action keys, sorted
      def keys_for(resource_name)
        for_resource(resource_name).map(&:key).uniq
      end

      # @return [Boolean] whether any listed controller runs the guard (see
      #   ControllerActions.guarded?). When false, permitting or blocking an
      #   action changes nothing at runtime.
      def any_guarded?
        entries.any?(&:guarded)
      end

      private

      # { ['customers', 'export'] => { verbs: ['GET'], paths: ['/customers/export'] } }
      def routed_actions
        @routes.routes.each_with_object({}) do |route, found|
          routed = RoutedAction.new(route)
          routed.merge_into(found) if listed?(routed.target)
        end
      end

      # Has a static target, and its controller is not excluded from discovery.
      def listed?(target)
        target && !@configuration.controller_excluded?(target.first)
      end

      def build_entry(path, action, route)
        klass = controller_class(path)
        target = ControllerActions::Mapping.call(controller_path: path, action_name: action, controller_class: klass,
                                                 configuration: @configuration, conventions: @conventions)
        return nil unless target&.manageable?

        Entry.new(controller_path: path, action_name: action, verbs: route[:verbs].sort, paths: route[:paths].sort,
                  resource: target.resource, key: target.action, crud: target.crud,
                  guarded: ControllerActions.guarded?(klass))
      rescue StandardError => e
        log_skipped("#{path}##{action}", e)
        nil
      end

      # The controller's class, or nil when it does not exist or cannot be loaded.
      def controller_class(path)
        @controller_classes.fetch(path) { @controller_classes[path] = load_controller(path) }
      end

      # A controller file that fails to load must not take the catalog down.
      def load_controller(path)
        ControllerActions.controller_class_for(path)
      rescue StandardError, ScriptError => e
        log_skipped(path, e)
        nil
      end

      # Logged once per catalog: a raising resolver would otherwise repeat the
      # same line for every route.
      def log_skipped(what, error)
        return if @logged

        @logged = true
        Rails.logger&.warn("[PermissionForge] controller catalog skipped #{what}: #{error.class}: #{error.message}")
      end
    end
  end
end
