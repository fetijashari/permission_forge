module PermissionForge
  # The membership of a user in a Permission Set Group (unique per user and group).
  #
  # @api public
  class PermissionSetGroupUser < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_set_group_users"

    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::RecordsAuditEvents

    # optional: is stated (see PermissionSetUser): the group is optional as
    # declared since 0.13, the user is required.
    belongs_to :permission_set_group, class_name: 'PermissionForge::PermissionSetGroup', optional: true
    belongs_to :user, class_name: PermissionForge.configuration.user_class, optional: false

    # Mirrors the DB unique index so a repeat assignment returns a 422 instead of
    # a RecordNotUnique 500 (and prevents silent duplicate rows on schemas that
    # predate the index).
    validates :user_id, uniqueness: { scope: :permission_set_group_id,
                                      message: ->(*) { I18n.t('permission_forge.validations.permission_set_group_user.taken') } }

    # See PermissionSetUser: never store a truncated user key.
    before_validation { PermissionForge::Services::HostKeyGuard.verify! }

    # The reason of the change in progress (Audit::Context) is kept on the row.
    before_save :keep_audit_reason

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    private

    def keep_audit_reason
      reason = PermissionForge::Audit::Context[:reason]
      return if reason.blank? || !has_attribute?(:reason)
      return unless new_record? || changed?

      self.reason = PermissionForge::Audit::ColumnValues.value(reason.to_s)
    end
  end
end
