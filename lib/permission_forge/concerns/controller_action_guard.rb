# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Runtime guard for host controllers: checks every action against the
    # current user's Permission Sets before it runs.
    #
    #   class CustomersController < ApplicationController
    #     include PermissionForge::Concerns::ControllerActionGuard
    #   end
    #
    #   class Customers::MergesController < ApplicationController
    #     include PermissionForge::Concerns::ControllerActionGuard
    #     permission_forge_actions resource: 'Customer', actions: { create: :merge }
    #   end
    #
    # The guard never renders or redirects. A denied action raises
    # PermissionForge::ActionNotAuthorizedError — rescue it in the host app:
    #
    #   rescue_from PermissionForge::ActionNotAuthorizedError do
    #     head :forbidden
    #   end
    #
    # The decision itself lives in {PermissionForge::ControllerActions::Authorizer}.
    #
    # @api public
    module ControllerActionGuard
      extend ActiveSupport::Concern

      included do
        # The controller's declaration, in the shape ControllerActions::Mapping
        # reads. Class-level only: a public instance reader would be routable
        # as a controller action.
        class_attribute :pf_action_guard_options, instance_accessor: false, instance_predicate: false,
                                                  default: PermissionForge::ControllerActions::EMPTY_OPTIONS

        before_action :pf_authorize_action!
      end

      class_methods do
        # Declares which Resource and action keys this controller's actions
        # mean. Subclasses inherit the declaration. Declaring again — in the
        # same class or a subclass — adds to it: a given resource or
        # rest_actions replaces, actions are merged.
        #
        # @param resource [String, Symbol, Class, nil] Resource name; nil keeps
        #   the convention (controller name → model)
        # @param actions [Hash] controller action name => action key
        #   (`{ create: :merge }`); a CRUD word (`:edit`) checks that CRUD flag
        # @param rest_actions [Boolean, nil] false leaves index/show/new/create/
        #   edit/update/destroy unchecked unless listed in `actions`; nil keeps
        #   the current setting (checked, unless an earlier declaration said false)
        # @return [Hash] the normalized, frozen declaration
        # @raise [ArgumentError] when the resource or a key is not a valid name
        def permission_forge_actions(resource: nil, actions: {}, rest_actions: nil)
          self.pf_action_guard_options = PermissionForge::ControllerActions.merge_options(
            pf_action_guard_options, resource: resource, actions: actions, rest_actions: rest_actions
          )
        end
      end

      private

      # A denial is published as action.denied, an allowed request that
      # skipped the Permission Sets (no user under :bypass, the bypass lambda,
      # an action nobody manages) as rule.bypassed.
      #
      # @raise [PermissionForge::ActionNotAuthorizedError] when the current
      #   user may not run this action
      def pf_authorize_action!
        user = PermissionForge.current_user
        decision = PermissionForge::ControllerActions::Authorizer.call(
          controller_path: controller_path, action_name: action_name, controller: self, user: user
        )
        return pf_action_allowed(decision, user) if decision.allowed?

        target = decision.target
        pf_action_denied(decision, user)
        raise PermissionForge::ActionNotAuthorizedError.new(
          resource: target.resource, action: target.action, controller_path: controller_path,
          reason: decision.reason, user: user
        )
      end

      def pf_action_allowed(decision, user)
        reason = decision.bypass_reason
        return unless reason

        PermissionForge::Audit::Runtime.bypassed(reason, model: decision.target.resource, via: 'action_guard', user: user,
                                                         data: pf_action_event_data(decision))
      end

      def pf_action_denied(decision, user)
        PermissionForge::Audit::Runtime.denied(
          PermissionForge::Audit::Runtime::ACTION_DENIED, reason: decision.reason, model: decision.target.resource,
                                                          via: 'action_guard', user: user,
                                                          data: pf_action_event_data(decision)
        )
      end

      def pf_action_event_data(decision)
        { 'action' => decision.target.action, 'controller' => controller_path, 'action_name' => action_name }
      end
    end
  end
end
