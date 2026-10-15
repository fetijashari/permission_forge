module PermissionForge
  # An optional grouping of Permission Sets that is assigned to people as one.
  #
  # @api public
  class PermissionSetGroup < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_set_groups"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::RecordsAuditEvents

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

    # Deleting a group detaches its sets (detach_permission_sets) — not
    # `dependent: :nullify`, whose UPDATE runs no callbacks and so leaves no
    # audit event. A set removed from the collection (`delete`, `ids=`, `=`,
    # `clear`) is detached the same way by `before_remove`, so Rails' own
    # nullify that follows finds nothing left to change. Never
    # `dependent: :destroy` here: that would delete the sets.
    has_many :permission_sets, class_name: 'PermissionForge::PermissionSet',
                               before_remove: :detach_permission_set, extend: Concerns::AuditedCollection
    has_many :permission_set_group_users, class_name: 'PermissionForge::PermissionSetGroupUser', dependent: :destroy,
                                          extend: Concerns::AuditedCollection
    # Destroys the membership rows, never a person.
    has_many :users, through: :permission_set_group_users, dependent: :destroy, extend: Concerns::AuditedCollection

    # Checked for a new row and on a rename only: a row whose name was
    # blank before 0.14 stays editable in its other attributes.
    validates :name, presence: { message: ->(*) { I18n.t('permission_forge.validations.name_blank') } },
                     if: -> { new_record? || will_save_change_to_name? }

    before_destroy :detach_permission_sets

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # Deep-clones this group with all its permission sets and their resources/fields/rules.
    # Does NOT copy user assignments — the clone starts with no users.
    def deep_clone(attrs = {})
      PermissionForge::Services::PermissionSetGroupCloner.call(permission_set_group: self, attrs: attrs)
    end

    private

    # before_remove of #permission_sets: an audited save (a
    # `permission_set.updated` event) instead of Rails' UPDATE. The row is
    # what counts, not the instance: one loaded before the set joined this
    # group still has the old foreign key, so the stored row is detached.
    def detach_permission_set(set)
      return unless set.persisted?

      set = in_record_tenant(PermissionForge::PermissionSet).find_by(id: set.id, permission_set_group_id: id) unless
        set.permission_set_group_id == id
      return unless set

      set.permission_set_group_id = nil
      set.save!(validate: false)
    end

    # One audited save per set (a `permission_set.updated` event each, in the
    # destroy's transaction, so they share its correlation id). The sets are
    # read in the group's own tenant. Validation is skipped: a set that an
    # unrelated rule would now refuse (a legacy over-long name) must still let
    # go of a group that is being deleted.
    def detach_permission_sets
      in_record_tenant(PermissionForge::PermissionSet).where(permission_set_group_id: id).find_each do |set|
        set.permission_set_group_id = nil
        set.save!(validate: false)
      end
    end

    def users_on_permission_set
      return [] unless is_active

      ps_ids = in_record_tenant(PermissionForge::PermissionSet).where(permission_set_group_id: id, is_active: true).pluck(:id)
      return [] if ps_ids.empty?

      in_record_tenant(PermissionForge::PermissionSetUser).where(permission_set_id: ps_ids)
    end
  end
end
