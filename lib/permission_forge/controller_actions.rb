# frozen_string_literal: true

module PermissionForge
  # Controller actions as permissions: which Resource and action key a
  # controller action means (Mapping), whether any Permission Set manages it
  # (ManagedIndex), and whether a user may run it (Authorizer).
  #
  # @api private
  module ControllerActions
    # Format of a ResourceAction name, and so of every action key.
    KEY_FORMAT = /\A[a-z][a-z0-9_]{0,62}\z/

    # A Resource name: a Ruby constant path (the one definition is
    # PermissionForge::RESOURCE_NAME_FORMAT; the Resource model is autoloaded
    # later than this file).
    RESOURCE_FORMAT = PermissionForge::RESOURCE_NAME_FORMAT

    # The before_action the guard concern installs.
    GUARD_CALLBACK = :pf_authorize_action!

    # Controller action names that mean a CRUD permission on the resource.
    REST_ACTIONS = {
      'index' => :read, 'show' => :read,
      'new' => :create, 'create' => :create,
      'edit' => :edit, 'update' => :edit,
      'destroy' => :delete
    }.freeze

    # Action keys PermissionedUser#can? answers from the CRUD flags instead of
    # the resource's custom actions — can?'s own table, so the two cannot drift.
    CRUD_KEYS = PermissionForge::Concerns::ResourcePermissionChecker::CRUD_ACTIONS.transform_keys(&:to_s).freeze

    EMPTY_OPTIONS = { resource: nil, actions: {}.freeze, rest_actions: true }.freeze

    # Normalizes a controller's `permission_forge_actions` declaration into the
    # frozen shape Mapping reads. The only constructor of that shape, so it is
    # also where a declaration is validated.
    #
    # @param resource [String, Symbol, Class, nil]
    # @param actions [Hash] controller action name => action key
    # @param rest_actions [Boolean] false leaves index/show/new/... unmanaged
    # @return [Hash] { resource: String|nil, actions: { String => String }, rest_actions: Boolean }
    # @raise [ArgumentError] when the resource or a key is not a valid name
    def self.normalize_options(resource: nil, actions: {}, rest_actions: true)
      options = {
        resource: resource_name(resource),
        actions: actions.to_h.to_h { |name, key| [name.to_s, key.to_s] }.freeze,
        rest_actions: rest_actions != false
      }.freeze
      validate_options!(options)
      options
    end

    # Adds a declaration to the one a controller already has — its own earlier
    # call, or an inherited one. A given resource or rest_actions replaces;
    # actions are merged. Declaring twice therefore never drops the resource
    # the first call named (which would leave the controller unchecked).
    #
    # @param current [Hash] a normalized declaration
    # @return [Hash] a normalized, frozen declaration
    def self.merge_options(current, **declaration)
      rest_actions = declaration.fetch(:rest_actions, nil)
      given = normalize_options(**declaration, rest_actions: rest_actions.nil? ? current[:rest_actions] : rest_actions)
      { resource: given[:resource] || current[:resource],
        actions: current[:actions].merge(given[:actions]).freeze,
        rest_actions: given[:rest_actions] }.freeze
    end

    # A declaration the mapping could not use fails here, when the controller
    # loads. Left alone, a typo (`resource: 'customer'`, `actions: { create:
    # 'Merge' }`) would map the action to nothing and leave it unchecked.
    def self.validate_options!(options)
      resource = options[:resource]
      if resource && !resource.match?(RESOURCE_FORMAT)
        raise ArgumentError, "permission_forge_actions: #{resource.inspect} is not a Resource name " \
                             "(expected a model name such as 'Customer')"
      end

      invalid = options[:actions].values.grep_v(KEY_FORMAT)
      return if invalid.empty?

      raise ArgumentError, "permission_forge_actions: invalid action key #{invalid.map(&:inspect).join(', ')} " \
                           '(expected lowercase letters, digits and _, starting with a letter)'
    end
    private_class_method :validate_options!

    # 'api/v1/customers' → Api::V1::CustomersController, the way the router
    # names it; nil when there is no such class.
    #
    # @param controller_path [String]
    # @return [Class, nil]
    def self.controller_class_for(controller_path)
      "#{controller_path}_controller".camelize.safe_constantize
    end

    # Whether the controller runs the guard: it includes the concern and has
    # not removed the callback with a blanket skip_before_action. (A skip
    # limited with only:/except: still counts as guarded.)
    #
    # @param controller_class [Class, nil]
    # @return [Boolean]
    # @raise [PermissionForge::ConfigurationError] when the controller's
    #   before_action chain cannot be read (`_process_action_callbacks`, a
    #   Rails internal): the answer is not guessed either way
    def self.guarded?(controller_class)
      return false unless controller_class.respond_to?(:pf_action_guard_options)
      unless controller_class.respond_to?(:_process_action_callbacks)
        raise PermissionForge::ConfigurationError,
              "PermissionForge cannot read the before_action chain of #{controller_class} (_process_action_callbacks, " \
              "ActionPack #{ActionPack.version}): this version of the gem does not support that Rails version"
      end

      controller_class._process_action_callbacks.any? { |callback| callback.filter == GUARD_CALLBACK }
    end

    def self.resource_name(resource)
      name = resource.is_a?(Module) ? resource.name : resource
      name.to_s.presence
    end
    private_class_method :resource_name
  end
end
