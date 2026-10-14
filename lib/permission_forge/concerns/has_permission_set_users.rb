# frozen_string_literal: true

module PermissionForge
  module Concerns
    # Provides `users_on_permission_set` required by {PermissionsRegenerator},
    # and `user_ids_on_permission_set`, the ids of their users, plucked
    # without loading a row (what the invalidation uses).
    #
    # Include this concern and declare the lookup strategy based on how the model
    # relates to a permission set:
    #
    #   permission_set_user_lookup :self         # PermissionSet (has permission_set_users directly)
    #   permission_set_user_lookup :direct       # Has permission_set_id column
    #   permission_set_user_lookup :via_resource # Has resource_id -> resource -> permission_set
    #
    # Inside after_commit the queries go through the commit's InvalidationBatch
    # (InvalidatesInBatch), so the records of one Permission Set written in one
    # transaction look its assignments up once. Anywhere else every call
    # queries afresh. Every lookup follows the record's tenant, not the
    # ambient one.
    #
    # @api private
    module HasPermissionSetUsers
      extend ActiveSupport::Concern
      include InvalidatesInBatch

      # Which Permission Sets the record's change affects, by strategy.
      LOOKUPS = {
        self: :self_permission_set_ids,
        direct: :direct_permission_set_ids,
        via_resource: :via_resource_permission_set_ids
      }.freeze

      included do
        # a record moved to another set or resource: see #direct_permission_set_ids
        after_save { %w[permission_set_id resource_id].each { |column| note_previous_value(column) } }
      end

      class_methods do
        # @param strategy [:self, :direct, :via_resource]
        def permission_set_user_lookup(strategy)
          lookup = LOOKUPS.fetch(strategy) do
            raise ArgumentError, "Unknown strategy: #{strategy}. Use :self, :direct, or :via_resource"
          end

          # on the class itself: these win over PermissionsRegenerator's defaults
          define_method(:affected_permission_set_ids) { send(lookup) }
          define_method(:users_on_permission_set) { assignments_of_affected_sets }
          define_method(:user_ids_on_permission_set) { holder_ids_of_affected_sets }
          private :affected_permission_set_ids, :users_on_permission_set, :user_ids_on_permission_set
        end
      end

      private

      # @return [Array<PermissionForge::PermissionSetUser>]
      def assignments_of_affected_sets
        affected_permission_set_ids.flat_map { |set_id| permission_set_assignments(set_id).to_a }
      end

      # @return [Array] the holders' user ids, without duplicates
      def holder_ids_of_affected_sets
        affected_permission_set_ids.flat_map { |set_id| permission_set_user_ids(set_id) }.uniq
      end

      def self_permission_set_ids
        [id]
      end

      # A record moved to another Permission Set (or resource) changes what
      # both grant, so the users of both are affected — every set it left
      # since the last commit (InvalidatesInBatch#note_previous_value).
      def direct_permission_set_ids
        [permission_set_id, *previous_values('permission_set_id')].compact_blank.uniq.reject do |set_id|
          shared_lookup(:inactive_permission_set, set_id) { permission_set_exists?(set_id, active: false) }
        end
      end

      def via_resource_permission_set_ids
        [resource_id, *previous_values('resource_id')].compact_blank.uniq.filter_map do |parent_id|
          set_id = shared_lookup(:permission_set_of_resource, parent_id) do
            in_record_tenant(PermissionForge::Resource).where(id: parent_id).pick(:permission_set_id)
          end
          next if set_id.blank?

          set_id if shared_lookup(:active_permission_set, set_id) { permission_set_exists?(set_id, active: true) }
        end
      end

      # The assignments of a Permission Set in this record's tenant (see
      # InvalidatesInBatch#in_record_tenant).
      def permission_set_assignments(set_id)
        shared_lookup(:assignments, set_id) do
          in_record_tenant(PermissionForge::PermissionSetUser).where(permission_set_id: set_id)
        end
      end

      # Their user ids, plucked: a set may have thousands of holders, and
      # nothing but the id is needed to invalidate them.
      def permission_set_user_ids(set_id)
        shared_lookup(:assignment_user_ids, set_id) { permission_set_assignments(set_id).distinct.pluck(:user_id) }
      end

      def permission_set_exists?(set_id, active:)
        in_record_tenant(PermissionForge::PermissionSet).where(id: set_id, is_active: active).exists?
      end

      # The lookups depend on the record's tenant, so it is part of every key:
      # records of two tenants in one commit do not share an answer.
      def shared_lookup(*key, &)
        invalidation_batch.fetch([permission_record_tenant_id, *key], &)
      end
    end
  end
end
