module PermissionForge
  # Column-level read, edit and mask access to one field of a resource.
  #
  # @api public
  class ResourceField < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}resource_fields"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::KeepsCopiedValues
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::ValidatesDependency
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::RecordsAuditEvents

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

    permission_set_user_lookup :via_resource

    # The install migration's column default for label: a row created
    # without one (the API, the console) would show it everywhere the admin
    # names the field.
    UNTITLED_LABEL = 'Untitled Field'.freeze

    before_validation :default_label, on: :create

    # optional: as declared since 0.13 (the foreign key holds); stated, so the
    # host's belongs_to_required_by_default decides nothing here.
    belongs_to :resource, class_name: 'PermissionForge::Resource', optional: true

    # Active rows of active resources of active Permission Sets — the rows the
    # engine merges. A switched-off row counts as no row.
    scope :in_effect, lambda {
      active.joins(resource: :permission_set)
            .merge(PermissionForge::Resource.active).merge(PermissionForge::PermissionSet.active)
    }

    # The rows that show a field in the clear — the SQL twin of
    # #exposes_in_clear? (a test pins that they agree). The set's direction
    # is the caller's: `in_effect.merge(PermissionSet.granting)` for the
    # rows that reach someone's hash.
    scope :exposing_in_clear, -> { active.where(read_access: true, mask_access: false) }

    # The rows in the clear nobody marked "This is intended" in the admin's
    # privacy audit (sensitive_acknowledged_at) — the SQL twin of
    # #exposes_unacknowledged?, what the GDPR audit, the security audit,
    # Home and the boot warning report.
    scope :exposing_unacknowledged, lambda {
      acknowledgement_supported? ? exposing_in_clear.where(sensitive_acknowledged_at: nil) : exposing_in_clear
    }

    # Whether the table has the column "This is intended" writes (added by
    # the upgrade generator; an older install has none, and nothing is
    # acknowledged there).
    #
    # @return [Boolean]
    def self.acknowledgement_supported?
      PermissionForge::SchemaRead.column?(self, 'sensitive_acknowledged_at', ignored: false)
    rescue StandardError
      false
    end

    # The rows in effect that mask with a strategy this app does not know
    # (Services::MaskValue.known?): written past the model, or a custom
    # strategy since removed. Masked fully until fixed. The one reading the
    # security audit's unknown_mask_strategies and Home's card both take.
    #
    # @return [Array<ResourceField>] with their Resource and Permission Set loaded
    def self.with_unknown_mask_strategy
      in_effect.where(mask_access: true).includes(resource: :permission_set).order(:resource_id, :id)
               .reject { |field| PermissionForge::Services::MaskValue.known?(field.mask_strategy) }
    end

    # The one definition of "readable in the clear": an active row that
    # grants read and no mask. On a granting set's row only — a muting row
    # takes access away, so the question does not arise there. The GDPR
    # audit (unmasked_field, cross_set_unmasking), the security audit's
    # personal_data check, Home's privacy card and the boot warning all ask
    # this; a Hidden row (read off) is never in the clear, nor is a row
    # written past the validation with mask on and read off.
    #
    # @return [Boolean]
    def exposes_in_clear?
      is_active && read_access && !mask_access
    end

    # In the clear and not marked "This is intended": the one definition of
    # a personal-data exposure the four surfaces report (the field must
    # also look like personal data: SensitiveColumns).
    #
    # @return [Boolean]
    def exposes_unacknowledged?
      exposes_in_clear? && !acknowledged_as_intended?
    end

    # @return [Boolean] an admin marked the field "This is intended"
    def acknowledged_as_intended?
      self.class.acknowledgement_supported? && has_attribute?(:sensitive_acknowledged_at) && sensitive_acknowledged_at.present?
    end

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
    validates :name, uniqueness: { scope: :resource_id, message: ->(*) { I18n.t('permission_forge.validations.taken') } }

    validates_dependency :edit_access, requires: :read_access
    validates_dependency :mask_access, requires: :read_access

    # The strategy is checked for a new row and when it, or mask_access,
    # changes (mask_strategy_check_due?): a row whose strategy this app no
    # longer knows — written past the model, or a custom strategy since
    # removed from config.custom_mask_strategies — stays editable in its
    # other attributes. Its values are masked fully until it is fixed
    # (Services::MaskValue); `rake permission_forge:audit` lists it
    # (unknown_mask_strategies), the field drawer flags it.
    # A copy keeps its original's strategy (KeepsCopiedValues): it masks
    # fully, as the original does.
    keeps_copied :mask_access, :mask_strategy
    validates :mask_strategy, presence: {
                                message: ->(*) { I18n.t('permission_forge.validations.resource_field.mask_strategy_required') }
                              },
                              if: :mask_strategy_check_due?
    validates :mask_strategy, inclusion: {
                                in: ->(_) { PermissionForge::Services::MaskValue.strategies.keys },
                                message: ->(*) { I18n.t('permission_forge.validations.resource_field.invalid_mask_strategy') }
                              },
                              if: :mask_strategy_check_due?

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    private

    # A new row without a label (blank, or the column default) is labelled
    # as generated rows are: the humanized name. Only on create: a label an
    # admin set later is never replaced.
    def default_label
      return if name.blank? || (label.present? && label != UNTITLED_LABEL)

      self.label = name.to_s.humanize
    end

    def mask_access?
      mask_access == true
    end

    def mask_strategy_check_due?
      return false if copied_unchanged?(:mask_access, :mask_strategy)

      mask_access? && (new_record? || will_save_change_to_mask_strategy? || will_save_change_to_mask_access?)
    end
  end
end
