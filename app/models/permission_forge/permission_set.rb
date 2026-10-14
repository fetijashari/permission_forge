module PermissionForge
  # A named group of resource, field, action and rule grants (or, with `is_muting`, of revocations)
  # that is assigned to users.
  #
  # @api public
  class PermissionSet < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_sets"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::InvalidatesManagedActions
    include PermissionForge::Concerns::RecordsAuditEvents

    permission_set_user_lookup :self

    belongs_to :permission_set_group, class_name: 'PermissionForge::PermissionSetGroup', optional: true
    # Every collection removes through callbacks (an audit event each):
    # `dependent: :destroy` on :users destroys the assignment rows, never a
    # person; AuditedCollection covers `clear` / `delete_all`.
    has_many :resources, class_name: 'PermissionForge::Resource', dependent: :destroy, extend: Concerns::AuditedCollection
    has_many :permission_set_rules, class_name: 'PermissionForge::PermissionSetRule', dependent: :destroy,
                                    extend: Concerns::AuditedCollection
    has_many :permission_set_users, class_name: 'PermissionForge::PermissionSetUser', dependent: :destroy,
                                    inverse_of: :permission_set, extend: Concerns::AuditedCollection
    has_many :users, through: :permission_set_users, dependent: :destroy, extend: Concerns::AuditedCollection

    # Checked for a new row and on a rename only: a row whose name was
    # blank before 0.14 stays editable in its other attributes.
    validates :name, presence: { message: ->(*) { I18n.t('permission_forge.validations.name_blank') } },
                     if: -> { new_record? || will_save_change_to_name? }
    validates :name, length: { maximum: 255 }
    # A group id must name a group (of this tenant): optional, but never dangling.
    validates :permission_set_group,
              presence: { message: ->(*) { I18n.t('permission_forge.validations.permission_set.group_missing') } },
              if: -> { permission_set_group_id.present? && will_save_change_to_permission_set_group_id? }
    validates :allowed_hours_start, numericality: { in: 0..23, allow_nil: true }
    validates :allowed_hours_end, numericality: { in: 0..23, allow_nil: true }

    scope :muting, -> { where(is_muting: true) }
    scope :granting, -> { where(is_muting: false) }
    scope :conditional, lambda {
      where.not(requires_session_flag: [nil, ''])
           .or(where.not(allowed_ips: [nil, '']))
           .or(where.not(allowed_hours_start: nil))
    }
    scope :unconditional, lambda {
      where(requires_session_flag: [nil, ''])
        .where(allowed_ips: [nil, ''])
        .where(allowed_hours_start: nil)
    }

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    def active?
      is_active
    end

    def inactive?
      !is_active
    end

    def muting?
      is_muting
    end

    def granting?
      !is_muting
    end

    def conditional?
      requires_session_flag.present? || allowed_ips.present? || allowed_hours_start.present?
    end

    def unconditional?
      !conditional?
    end

    # Deep-clones this permission set with all resources, fields, and rules.
    # Does NOT copy user assignments — the clone starts with no users.
    def deep_clone(attrs = {})
      PermissionForge::Services::PermissionSetCloner.call(permission_set: self, attrs: attrs)
    end

    private

    # InvalidatesManagedActions: a new set has no resources yet and the index
    # holds no set names, so only switching a set on or off changes what is
    # managed. (Its resources drop the index themselves when they are added
    # or destroyed.)
    def managed_actions_changed?
      !previously_new_record? && saved_change_to_is_active?
    end
  end
end
