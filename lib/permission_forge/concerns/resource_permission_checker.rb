module PermissionForge
  module Concerns
    # CRUD permission checks, generic action dispatch, and resource-level hash accessors.
    # Depends on PermissionCacheAccessor for shared helpers.
    #
    # @api public
    module ResourcePermissionChecker
      extend ActiveSupport::Concern

      # The words can? answers from the resource's CRUD flags, and the
      # permission each one means. Anything else is a custom action.
      # ControllerActions reads this table too, so the guard and can? always
      # agree on which keys are CRUD.
      CRUD_ACTIONS = { read: :read, create: :create, edit: :edit, update: :edit, delete: :delete, destroy: :delete }.freeze
      CRUD_PREDICATES = { read: :can_read?, create: :can_create?, edit: :can_edit?, delete: :can_delete? }.freeze

      # @param resource [Symbol, String] resource name (e.g., :Customer)
      # @return [Boolean]
      def can_read?(resource)
        pf_check_resource_permission(resource, :read_access)
      end

      alias can_show? can_read?
      alias has_read_access? can_read?

      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can_create?(resource)
        pf_check_resource_permission(resource, :create_access)
      end

      alias can_create_new? can_create?
      alias has_create_access? can_create?

      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can_edit?(resource)
        pf_check_resource_permission(resource, :edit_access)
      end

      alias can_update? can_edit?
      alias has_edit_access? can_edit?

      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can_delete?(resource)
        pf_check_resource_permission(resource, :delete_access)
      end

      alias can_destroy? can_delete?
      alias has_delete_access? can_delete?

      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can_view_all?(resource)
        pf_check_resource_permission(resource, :view_all)
      end

      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can_modify_all?(resource)
        pf_check_resource_permission(resource, :modify_all)
      end

      # Returns the resource-level permissions hash (read_access, create_access, etc.).
      #
      # @param resource [Symbol, String] resource name
      # @return [Hash] permission flags, or empty hash if resource not found
      def permissions_for(resource)
        perms = pf_resource_permissions(resource)
        return {} if perms.blank?

        perms
      end

      # Returns the full resource entry including permissions, fields, actions, and rules.
      #
      # @param resource [Symbol, String] resource name
      # @return [Hash] full resource entry, or empty hash if not found
      def permissions_hash_for(resource)
        entry = pf_resource_name_permissions(resource)
        return {} if entry.blank?

        entry
      end

      # Checks if the user can perform an action on a resource.
      # Delegates CRUD actions to specific helpers; custom actions check resource_actions.
      #
      # @param action [Symbol, String] action name (:read, :create, :edit, :delete, or custom)
      # @param resource [Symbol, String] resource name
      # @return [Boolean]
      def can?(action, resource)
        action = action.to_sym
        resource = resource.to_s.to_sym unless resource.is_a?(Symbol)

        crud = CRUD_ACTIONS[action]
        return public_send(CRUD_PREDICATES.fetch(crud), resource) if crud

        resource_hash = pf_resource_name_permissions(resource)
        return false unless resource_hash

        resource_hash.dig(:actions, action, :is_permitted) == true
      end

      private

      def pf_check_resource_permission(resource, action)
        perms = pf_resource_permissions(resource)
        return false if perms.blank?

        perms[action]
      end
    end
  end
end
