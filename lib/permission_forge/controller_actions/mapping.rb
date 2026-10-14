# frozen_string_literal: true

module PermissionForge
  module ControllerActions
    # Resolves a controller action to the Resource and action key that govern
    # it. The runtime guard and the admin's controller catalog both go through
    # here, so the admin lists exactly what the guard checks.
    #
    # Resolution order, for the resource and for the action key independently:
    #   1. the controller's own `permission_forge_actions` declaration
    #   2. config.controller_action_resolver
    #   3. convention — controller name → model, action name → key
    #
    # @example
    #   Mapping.call(controller_path: 'api/v1/customers', action_name: 'export')
    #   # => #<struct resource="Customer", action="export", crud=nil>
    #   Mapping.call(controller_path: 'customers', action_name: 'index')
    #   # => #<struct resource="Customer", action="index", crud=:read>
    class Mapping
      # crud is the CRUD permission the action means (:read, :create, :edit,
      # :delete), or nil for a custom action checked by its key.
      Target = Struct.new(:resource, :action, :crud, keyword_init: true) do
        def crud? = !crud.nil?

        # What to ask PermissionedUser#can? for.
        def permission = crud || action

        # Whether the admin and the API can give this action a row: a CRUD
        # flag, or a key that is a valid ResourceAction name. An action whose
        # name is not a valid key (`exportCSV`) is still mapped, so the guard
        # checks it like any other — with no row for it, that means
        # unconfigured_action_strategy — instead of waving it through.
        def manageable? = crud? || action.match?(KEY_FORMAT)
      end

      def self.call(...) = new(...).call

      # @param conventions [Hash, nil] a caller-owned memo of controller_path =>
      #   conventional resource, for callers that map many actions at once (the
      #   admin's controller catalog). The guard passes none.
      def initialize(controller_path:, action_name:, controller_class: nil, configuration: PermissionForge.configuration,
                     conventions: nil)
        @controller_path = controller_path.to_s
        @action_name = action_name.to_s
        @controller_class = controller_class
        @configuration = configuration
        @conventions = conventions
      end

      # @return [Target, nil] nil when the action is excluded, unmapped or
      #   explicitly unmanaged
      # @raise [PermissionForge::ConfigurationError] when a declaration or the
      #   resolver names a resource or key that is not a valid name
      def call
        return nil if unmanaged?

        resource = resource_name
        return nil unless resource

        key = explicit_key || @action_name
        crud = crud_for(key)
        Target.new(resource: resource, action: key, crud: crud) unless crud && skip_rest_action?
      end

      private

      # Excluded controller, or the host resolver said "never managed".
      def unmanaged?
        @configuration.controller_excluded?(@controller_path) || resolved == false
      end

      def declared
        @declared ||= if @controller_class.respond_to?(:pf_action_guard_options)
                        @controller_class.pf_action_guard_options || EMPTY_OPTIONS
                      else
                        EMPTY_OPTIONS
                      end
      end

      # The host resolver's answer: [resource, key], false, or nil. A raising
      # resolver propagates, and so does an answer of any other shape —
      # treating either as "unmanaged" would fail open.
      def resolved
        return @resolved if defined?(@resolved)

        answer = @configuration.controller_action_resolver&.call(@controller_path, @action_name)
        unless answer.nil? || answer == false || answer.is_a?(Array)
          raise PermissionForge::ConfigurationError,
                "#{@controller_path}##{@action_name}: controller_action_resolver must return " \
                "[resource, key], false or nil, got #{answer.inspect}"
        end

        @resolved = answer
      end

      def resolved_pair
        resolved.is_a?(Array) ? resolved : []
      end

      # Declarations are validated when they are made (normalize_options);
      # resolver answers are validated here.
      def resource_name
        declared[:resource] || resolved_part(0, RESOURCE_FORMAT, 'Resource name') || conventional_resource
      end

      # A key the controller or the resolver chose, as opposed to the action name.
      def explicit_key
        return @explicit_key if defined?(@explicit_key)

        @explicit_key = declared[:actions][@action_name] || resolved_part(1, KEY_FORMAT, 'action key')
      end

      def resolved_part(index, format, kind)
        value = resolved_pair[index]&.to_s.presence
        value && valid!(value, format, kind)
      end

      # A resolver answer that cannot be used is a configuration bug. Raising
      # fails closed; treating it as "unmapped" would leave the action unchecked.
      def valid!(value, format, kind)
        return value if value.match?(format)

        raise PermissionForge::ConfigurationError,
              "#{@controller_path}##{@action_name}: #{value.inspect} is not a valid #{kind}"
      end

      # An explicit key means CRUD only when it is one of can?'s CRUD words
      # (`actions: { approve: :edit }`); an action name also counts when it is
      # a REST action.
      def crud_for(key)
        return CRUD_KEYS[key] if explicit_key

        REST_ACTIONS[key] || CRUD_KEYS[key]
      end

      def skip_rest_action?
        declared[:rest_actions] == false && explicit_key.nil? && REST_ACTIONS.key?(@action_name)
      end

      def conventional_resource
        return resolve_convention unless @conventions

        @conventions.fetch(@controller_path) { @conventions[@controller_path] = resolve_convention }
      end

      # 'api/v1/customers' → Api::V1::Customer, then Customer.
      def resolve_convention
        candidates = [@controller_path.classify, @controller_path.split('/').last.to_s.classify].uniq
        candidates.each do |candidate|
          klass = model_class(candidate)
          return klass.name if klass
        end
        nil
      end

      # safe_constantize answers nil for a missing constant. A model that
      # exists but fails to load raises, and that propagates: swallowing it
      # would turn the controller into "unmapped", which the guard allows.
      def model_class(name)
        return nil unless name.match?(RESOURCE_FORMAT)

        klass = name.safe_constantize
        klass if klass.is_a?(Class) && klass < ActiveRecord::Base && !klass.abstract_class?
      end
    end
  end
end
