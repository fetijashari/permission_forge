# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Mixin for user models providing permission checks, cache access, and field masking.
    #
    # Include this concern in your User model to enable permission-aware behavior:
    #
    #   class User < ApplicationRecord
    #     include PermissionForge::Concerns::PermissionedUser
    #   end
    #
    # This adds associations to permission sets/groups and provides methods to check
    # CRUD access, custom actions, and field-level masking for any resource.
    #
    # Composed of 3 focused sub-concerns:
    #   - PermissionCacheAccessor — cache read/write, shared hash navigation
    #   - ResourcePermissionChecker — CRUD checks, generic can?, hash accessors
    #   - FieldMaskChecker — field-level mask checks
    #
    # @api public
    module PermissionedUser
      extend ActiveSupport::Concern

      include PermissionCacheAccessor
      include ResourcePermissionChecker
      include FieldMaskChecker

      # `dependent: :destroy` on the :through associations makes Rails
      # destroy the JOIN rows (assignments, memberships) with their
      # callbacks when a set or group is removed from the collection
      # (`delete`, `ids=`, `=`) — an audit event and a cache invalidation
      # each. It never destroys the Permission Set or group itself.
      # AuditedCollection does the same for `clear` / `delete_all`.
      included do
        has_many :permission_set_users, class_name: 'PermissionForge::PermissionSetUser', foreign_key: :user_id,
                                        dependent: :destroy, extend: AuditedCollection
        has_many :permission_sets, through: :permission_set_users, class_name: 'PermissionForge::PermissionSet',
                                   dependent: :destroy, extend: AuditedCollection
        has_many :permission_set_group_users, class_name: 'PermissionForge::PermissionSetGroupUser',
                                              foreign_key: :user_id, dependent: :destroy, extend: AuditedCollection
        has_many :permission_set_groups, through: :permission_set_group_users,
                                         class_name: 'PermissionForge::PermissionSetGroup',
                                         dependent: :destroy, extend: AuditedCollection

        # Declared after the associations, so it runs after their
        # `dependent: :destroy`: those reach the ambient tenant's rows only.
        before_destroy :pf_destroy_permission_rows_in_other_tenants
      end

      private

      # The user's assignments and memberships in the other tenants go with
      # the user too (a reused id must not inherit them): each through its
      # callbacks — an audit event and a cache invalidation in its own
      # tenant — with that tenant ambient, so its set or group is found.
      # With no tenant ambient the associations above reached every row.
      def pf_destroy_permission_rows_in_other_tenants
        config = PermissionForge.configuration
        return unless PermissionForge.ambient_tenant

        [PermissionForge::PermissionSetUser, PermissionForge::PermissionSetGroupUser].each do |model|
          model.unscoped.where(user_id: id).find_each do |row|
            pf_destroy_in_own_tenant(row, row.public_send(config.tenant_association_name))
          end
        end
      end

      # A row without a tenant (older than tenancy, or an optional tenant
      # association) is destroyed with no tenant ambient, not the caller's.
      def pf_destroy_in_own_tenant(row, tenant)
        return ::ActsAsTenant.without_tenant { row.destroy! } if tenant.nil?

        PermissionForge.with_ambient_tenant(tenant) { row.destroy! }
      end
    end
  end
end
