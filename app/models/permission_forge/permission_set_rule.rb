module PermissionForge
  # A row-level query rule of a Permission Set: one operator applied to one field of one resource.
  #
  # @api public
  class PermissionSetRule < ActiveRecord::Base
    # The table name, with the configured prefix (read on every call, so a prefix set at runtime applies).
    def self.table_name = "#{PermissionForge.table_name_prefix}permission_set_rules"

    include PermissionForge::Concerns::HasActiveScope
    include PermissionForge::Operators::Constants
    include PermissionForge::Concerns::HasUuid
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::RecordsAuditEvents

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

    permission_set_user_lookup :direct

    # optional: as declared since 0.13 (the foreign keys hold); stated, so the
    # host's belongs_to_required_by_default decides nothing here.
    belongs_to :permission_set, class_name: 'PermissionForge::PermissionSet', optional: true
    belongs_to :resource, class_name: 'PermissionForge::Resource', optional: true
    scope :recently_deactivated, -> { where(is_active: false).where('updated_at > ?', 7.days.ago) }

    # join_type values that mean "filter on the model's own table". Any other
    # join_type is a join rule: auto_query_scoping skips it, so it only applies
    # through find_by/find_by! and permission_scoped.
    FILTER_JOIN_TYPES = [nil, '', 'filter'].freeze
    scope :join_type_rules, -> { where.not(join_type: FILTER_JOIN_TYPES) }

    # Whether a join_type means "filter on the model's own table": nothing,
    # blank or 'filter'. The one definition — the applier, the default scope
    # and the RLS generator all ask here, so a row written past the model's
    # validation is read the same way by all three.
    def self.filter_join_type?(join_type)
      join_type.blank? || join_type.to_s == 'filter'
    end

    def join_rule?
      !self.class.filter_join_type?(join_type)
    end

    validates :operator, inclusion: {
      in: OPERATORS,
      message: I18n.t('permission_forge.validations.permission_set_rule.invalid_operator',
                      default: 'is not a valid operator')
    }
    # An operator that takes no value (Operators::Validations.valueless?)
    # stores an empty one: the column is NOT NULL, and the natural API payload
    # for a null check has no field_value.
    before_validation { self.field_value = '' if field_value.nil? && valueless_operator? }

    validates :field_value, presence: {
      message: I18n.t('permission_forge.validations.permission_set_rule.field_value_required',
                      default: 'is required for this operator')
    }, unless: :valueless_operator?
    validates :join_type, inclusion: {
      in: JOIN_TYPES,
      message: I18n.t('permission_forge.validations.permission_set_rule.invalid_join_type',
                      default: 'is not a valid join type')
    }, allow_nil: true, allow_blank: false
    validates :field_name, presence: true
    validates :field_name, format: {
      with: /\A[a-zA-Z_][a-zA-Z0-9_.]*\z/,
      message: I18n.t('permission_forge.validations.permission_set_rule.invalid_field_name',
                      default: 'must be a valid column name (letters, numbers, underscores, dots)')
    }, allow_blank: true

    validate :validate_field_name_segments, if: :field_name_changed?
    validate :validate_field_value_for_operator

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    private

    def valueless_operator?
      PermissionForge::Operators::Validations.valueless?(operator)
    end

    # `flag.` or `a..b` passes the format above, but an empty segment makes it
    # another name than the one written (see Operators::RuleColumn.name?).
    # Checked for a new rule and on a rename only: a row that already carries
    # such a name stays editable in its other attributes (it matches nothing).
    def validate_field_name_segments
      return if field_name.blank? || errors[:field_name].any?
      return if PermissionForge::Operators::RuleColumn.name?(field_name)

      errors.add(:field_name, I18n.t('permission_forge.validations.permission_set_rule.invalid_field_name',
                                     default: 'must be a valid column name (letters, numbers, underscores, dots)'))
    end

    def validate_field_value_for_operator
      result = PermissionForge::Operators::Validations.validate(operator, field_value)
      errors.add(result[:field], result[:message]) if result
    end
  end
end
