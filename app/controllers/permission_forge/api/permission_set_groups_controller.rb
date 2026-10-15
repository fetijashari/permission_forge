# frozen_string_literal: true

module PermissionForge
  module Api
    class PermissionSetGroupsController < BaseController
      before_action :set_group, only: %i[show update destroy clone]

      def index
        scope = PermissionForge::PermissionSetGroup.order(:name)
        render_collection(scope, serializer_for(:permission_set_group))
      end

      def show
        render_record(@group, serializer_for(:permission_set_group))
      end

      def create
        group = PermissionForge::PermissionSetGroup.new(group_params)
        guard_mutation!(:create, group)
        return if performed?

        if group.save
          render_created(group, serializer_for(:permission_set_group))
        else
          render_validation_errors(group)
        end
      end

      def update
        guard_mutation!(:update, @group)
        return if performed?

        if @group.update(group_params)
          render_record(@group, serializer_for(:permission_set_group))
        else
          render_validation_errors(@group)
        end
      end

      def destroy
        guard_mutation!(:destroy, @group)
        return if performed?

        @group.destroy!
        head :no_content
      end

      def clone
        authorize_action!(:clone, @group)
        return if performed?

        # As the admin's Duplicate: the copy of the group and of its sets is
        # editable, and named "<name> (copy)" in the request's locale.
        name = pf_text_param(:name).presence || I18n.t('permission_forge.permission_sets.copy_name', name: @group.name)
        cloned = PermissionForge::Services::PermissionSetGroupCloner.call(
          permission_set_group: @group, attrs: { name: name, is_editable: true }, unlock: true
        )
        render_created(cloned, serializer_for(:permission_set_group))
      end

      private

      def set_group
        @group = find_record(PermissionForge::PermissionSetGroup)
      end

      def group_params
        pf_require_hash(:permission_set_group).permit(:name, :description, :is_active, :is_editable)
      end
    end
  end
end
