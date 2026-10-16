module PermissionForge
  # Entity-level CRUD access to one model (its `name`) inside one Permission Set.
  #
  # @api public
  class Resource < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}resources"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::RequiresName # name present, on create or rename
    include PermissionForge::Concerns::NormalizesLabel # a blank label is stored as nil
    include PermissionForge::Concerns::ValidatesRequiredColumns
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::ValidatesDependency
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::InvalidatesManagedActions
    include PermissionForge::Concerns::RecordsAuditEvents

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

    # A Ruby constant path: Resource#name is resolved to a model class.
    NAME_FORMAT = PermissionForge::RESOURCE_NAME_FORMAT

    permission_set_user_lookup :direct

    # Active rows of active Permission Sets — the rows that count right now.
    scope :in_effect, -> { active.joins(:permission_set).merge(PermissionForge::PermissionSet.active) }

    # A model named for the first time is masked in this process and every
    # other one (MaskingSync). Noted per save, consumed once committed.
    after_save :note_newly_named_model
    after_commit :announce_newly_named_model

    # optional: as declared since 0.13 (the foreign key holds); stated, so the
    # host's belongs_to_required_by_default decides nothing here.
    belongs_to :permission_set, class_name: 'PermissionForge::PermissionSet', optional: true
    has_many :resource_fields, class_name: 'PermissionForge::ResourceField', dependent: :destroy,
                               extend: Concerns::AuditedCollection
    has_many :resource_actions, class_name: 'PermissionForge::ResourceAction', dependent: :destroy,
                                extend: Concerns::AuditedCollection
    has_many :permission_set_rules, class_name: 'PermissionForge::PermissionSetRule', dependent: :destroy,
                                    extend: Concerns::AuditedCollection

    validates :name, uniqueness: { scope: :permission_set_id,
                                   message: ->(*) { I18n.t('permission_forge.validations.resource.name_taken') } }
    # Resource#name is resolved to a model class via safe_constantize (e.g. by
    # ResourceFieldGenerator and MaskedAttributes auto-apply), so constrain it to
    # a Ruby constant path. Prevents naming a resource after arbitrary strings.
    validates :name, format: { with: NAME_FORMAT, message: ->(*) { I18n.t('permission_forge.validations.resource.invalid_name') } },
                     allow_blank: true

    validates_dependency :edit_access, requires: :read_access
    validates_dependency :delete_access, requires: :read_access
    validates_dependency :modify_all, requires: :view_all

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # Fallback for installations that haven't added the label column yet.
    def label
      has_attribute?(:label) ? read_attribute(:label) : name
    end

    # For a loaded record: active, in an active Permission Set (see .in_effect).
    def in_effect?
      is_active && permission_set.is_active
    end

    # View All / Modify All skip every record rule on this resource.
    def rules_bypassed?
      view_all || modify_all
    end

    # Grants full CRUD access + read and edit on every field, unmasked (also
    # the columns that look like personal data, which GdprFieldAuditor and the
    # admin's privacy audit still report), for a resource on a permission set.
    # Intended for seeds, migrations, or console use only.
    def self.grant_full_access!(permission_set:, resource_name:)
      PermissionForge::Services::ResourceWithFieldsBuilder.call(
        permission_set: permission_set, resource_name: resource_name
      )
    end

    private

    # A blank label is stored as no label (NormalizesLabel): the admin names
    # the model from the host's translation (Admin::ModelLabel).
    def generated_label = nil

    def note_newly_named_model
      @pf_newly_named = true if previously_new_record? || saved_change_to_name?
    end

    # The concern is applied here whatever the other rows; the other
    # processes are told when no other row (in any tenant) had the name, or
    # this process had not masked the model yet (MaskingSync.named!, which
    # asks for the other rows only when the answer decides something).
    def announce_newly_named_model
      return unless @pf_newly_named && persisted?

      @pf_newly_named = false
      PermissionForge::MaskingSync.named!(name) { self.class.unscoped.where(name: name).where.not(id: id).exists? }
    end
  end
end
