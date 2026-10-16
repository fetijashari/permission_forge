module PermissionForge
  # A custom action (such as sync or export) that a Permission Set permits or withholds on a resource.
  #
  # @api public
  class ResourceAction < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}resource_actions"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::ValidatesRequiredColumns
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::InvalidatesManagedActions
    include PermissionForge::Concerns::RecordsAuditEvents

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

    permission_set_user_lookup :via_resource

    # optional: as declared since 0.13 (the foreign key holds); stated, so the
    # host's belongs_to_required_by_default decides nothing here.
    belongs_to :resource, class_name: 'PermissionForge::Resource', optional: true

    # One row per (resource, name): two rows would be OR-ed, so a second row
    # could permit what the first one blocks. New installs also have a DB unique
    # index (idx_pf_resource_actions_unique); the validation surfaces a 422
    # instead of a RecordNotUnique 500. Checked when a row is created, renamed
    # or moved, so duplicates that predate the index stay editable; the
    # security audit lists them (`duplicate_actions`).
    # Checked for a new row and on a rename only: a row whose name was
    # blank before 0.14 stays editable in its other attributes.
    validates :name, presence: { message: ->(*) { I18n.t('permission_forge.validations.name_blank') } },
                     if: -> { new_record? || will_save_change_to_name? }
    validates :name, uniqueness: { scope: :resource_id,
                                   message: ->(*) { I18n.t('permission_forge.errors.admin.action_taken') } },
                     if: -> { new_record? || will_save_change_to_name? || will_save_change_to_resource_id? }

    # Active rows of active resources of active Permission Sets. An action with
    # such a row is "managed": only people a set permits can run it.
    scope :in_effect, lambda {
      active.joins(resource: :permission_set)
            .merge(PermissionForge::Resource.active).merge(PermissionForge::PermissionSet.active)
    }

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # For a loaded record (see .in_effect).
    def in_effect?
      is_active && resource.in_effect?
    end

    # @return [String] the label, or the name as stored when there is none (Admin::ActionLabel)
    def display_name
      PermissionForge::Admin::ActionLabel.for(self).text
    end
  end
end
