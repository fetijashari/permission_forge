module PermissionForge
  # Column-level read, edit and mask access to one field of a resource.
  #
  # @api public
  class ResourceField < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}resource_fields"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::ValidatesDependency
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::RecordsAuditEvents

    permission_set_user_lookup :via_resource

    # optional: as declared since 0.13 (the foreign key holds); stated, so the
    # host's belongs_to_required_by_default decides nothing here.
    belongs_to :resource, class_name: 'PermissionForge::Resource', optional: true

    # Active rows of active resources of active Permission Sets — the rows the
    # engine merges. A switched-off row counts as no row.
    scope :in_effect, lambda {
      active.joins(resource: :permission_set)
            .merge(PermissionForge::Resource.active).merge(PermissionForge::PermissionSet.active)
    }

    # A duplicate (resource_id, name) row would let a second field entry with
    # mask_access: false silently unmask the field via FieldPermissionMerger's
    # AND logic. Enforced by a DB unique index (idx_pf_resource_fields_unique)
    # as well; the validation surfaces a 422 instead of a RecordNotUnique 500.
    # No case_sensitive option: the check then compares the way the column's
    # collation does, and so the way the index does. On MySQL's default
    # (case-insensitive) collation "Email" collides with "email" in the index;
    # a forced case-sensitive check would let it through to a RecordNotUnique.
    # Checked for a new row and on a rename only: a row whose name was
    # blank before 0.14 stays editable in its other attributes.
    validates :name, presence: { message: ->(*) { I18n.t('permission_forge.validations.name_blank') } },
                     if: -> { new_record? || will_save_change_to_name? }
    validates :name, uniqueness: { scope: :resource_id }

    validates_dependency :edit_access, requires: :read_access
    validates_dependency :mask_access, requires: :read_access

    validates :mask_strategy, presence: {
                                message: I18n.t('permission_forge.validations.resource_field.mask_strategy_required',
                                                default: 'must be present when mask access is enabled')
                              },
                              if: :mask_access?
    validates :mask_strategy, inclusion: {
                                in: ->(_) { PermissionForge::Services::MaskValue.strategies.keys },
                                message: I18n.t('permission_forge.validations.resource_field.invalid_mask_strategy',
                                                default: 'is not a valid mask strategy')
                              },
                              if: :mask_access?

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    private

    def mask_access?
      mask_access == true
    end
  end
end
