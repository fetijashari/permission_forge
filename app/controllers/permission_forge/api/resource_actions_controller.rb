# frozen_string_literal: true

module PermissionForge
  module Api
    class ResourceActionsController < BaseController
      include CrudActions
      include NestedResourceLookup

      before_action :set_resource
      before_action :set_action, only: %i[show update destroy]

      private

      def collection_scope = @resource.resource_actions
      def current_record = @action
      def serializer_type = :resource_action

      def set_action
        @action = find_nested_record(@resource.resource_actions)
      end

      def record_params
        pf_require_hash(:resource_action).permit(:name, :label, :description, :is_permitted, :is_active)
      end

      # A create or a rename must also name a valid action key. Checked after
      # the base checks (authorization, editable lock), so a caller who may
      # not change the record gets its 403 first.
      def guard_mutation!(action, record)
        super
        reject_invalid_key!(record) unless performed? || action == :destroy
      end

      # Action keys follow ControllerActions::KEY_FORMAT: the admin form, the
      # controller catalog and permission_forge_actions accept nothing else.
      # A row named "Export" or "archive " is not the key of `export` or
      # `archive`: it would read as a restriction in the admin while that
      # controller action stays unmanaged. Checked here rather than in a model
      # validation, so rows that already carry such a name can still be edited
      # and cloned.
      def reject_invalid_key!(record)
        name = requested_name
        return if name.nil? || name.match?(PermissionForge::ControllerActions::KEY_FORMAT)

        record.errors.add(:name, I18n.t('permission_forge.errors.admin.action_format'))
        render_validation_errors(record)
      end

      # The name a create or a rename asks for; nil when an update keeps the
      # name the row has.
      def requested_name
        current = current_record&.name
        name = record_params.fetch(:name, current).to_s
        name unless name == current
      end
    end
  end
end
