# frozen_string_literal: true

module PermissionForge
  module Api
    class PermissionSetsController < BaseController
      before_action :set_permission_set, only: %i[show update destroy clone]

      def index
        scope = PermissionForge::PermissionSet.order(created_at: :desc)
        render_collection(scope, serializer_for(:permission_set))
      end

      def show
        render_record(@permission_set, serializer_for(:permission_set))
      end

      def create
        ps = PermissionForge::PermissionSet.new(permission_set_params)
        guard_mutation!(:create, ps)
        return if performed?

        save_set(ps) { render_created(ps, serializer_for(:permission_set)) }
      end

      # The lock is checked on the stored set, before the request's
      # attributes (is_editable among them) are assigned.
      def update
        guard_mutation!(:update, @permission_set)
        return if performed?

        @permission_set.assign_attributes(permission_set_params)
        save_set(@permission_set) { render_record(@permission_set, serializer_for(:permission_set)) }
      end

      def destroy
        guard_mutation!(:destroy, @permission_set)
        return if performed?

        @permission_set.destroy!
        head :no_content
      end

      def clone
        authorize_action!(:clone, @permission_set)
        return if performed?

        # As the admin's Duplicate: an editable copy, outside a locked group.
        # Names are unique per tenant: the default one is the admin's
        # "<name> (copy)" in the request's locale, numbered when taken.
        cloned = PermissionForge::Admin::PermissionSetFactory.duplicate(
          @permission_set, name: pf_copy_name.presence || PermissionForge::PermissionSet.copy_name(@permission_set.name)
        )
        render_created(cloned, serializer_for(:permission_set))
      end

      private

      # Saves a set whose attributes are assigned, unless it would enter or
      # leave a locked Permission Set Group (as the admin's group page
      # refuses); yields to render on success.
      def save_set(permission_set)
        locked = locked_group_for_move(permission_set)
        return reject_locked!(locked) if locked

        permission_set.save ? yield : render_validation_errors(permission_set)
      end

      def locked_group_for_move(permission_set)
        return unless permission_set.permission_set_group_id_changed?

        PermissionForge::Admin::EditableLock.locked_group_for_move(
          from: permission_set.permission_set_group_id_was, to: permission_set.permission_set_group_id
        )
      end

      def set_permission_set
        @permission_set = find_record(PermissionForge::PermissionSet)
      end

      # The activation conditions take their shapes from Api::InputShapes
      # (allowed_ips a String or a list of Strings, an hour digits, a flag
      # text; null or "" clears); permission_set_group_id takes the group's
      # id or, under api_record_identifier = :uuid, its uuid
      # (BaseController#with_reference_id).
      def permission_set_params
        attrs = pf_record_attributes(:permission_set, PermissionForge::PermissionSet,
                                     :name, :description, :is_active, :is_editable, :is_muting, :permission_set_group_id,
                                     :requires_session_flag, :allowed_hours_start, :allowed_hours_end, :allowed_ips)
        with_reference_id(attrs, :permission_set_group_id, PermissionForge::PermissionSetGroup)
      end
    end
  end
end
