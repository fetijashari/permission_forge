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

    # What a rule names is checked for a new rule and when it changes (the
    # *_check_due? predicates): a row saved before a check, or written past
    # the model (the tables are shared with other applications; a newer
    # version in a rolling deploy), stays editable in its other attributes.
    # Such a row matches nothing (Operators::RuleProblem — the applier, the
    # audit's rule check and the admin's Home all read it).
    validates :operator, inclusion: {
      in: OPERATORS, message: ->(*) { I18n.t('permission_forge.validations.permission_set_rule.invalid_operator') }
    }, if: :operator_check_due?
    # An operator that takes no value (Operators::Validations.valueless?)
    # stores an empty one: the column is NOT NULL, and the natural API payload
    # for a null check has no field_value.
    before_validation { self.field_value = '' if field_value.nil? && valueless_operator? }

    validates :field_value, presence: {
      message: ->(*) { I18n.t('permission_forge.validations.permission_set_rule.field_value_required') }
    }, unless: :valueless_operator?
    validates :join_type, inclusion: {
      in: JOIN_TYPES, message: ->(*) { I18n.t('permission_forge.validations.permission_set_rule.invalid_join_type') }
    }, allow_nil: true, allow_blank: false, if: :join_type_check_due?
    validates :field_name, presence: { message: ->(*) { I18n.t('permission_forge.validations.blank') } }
    validates :field_name, format: {
      with: /\A[a-zA-Z_][a-zA-Z0-9_.]*\z/,
      message: ->(*) { I18n.t('permission_forge.validations.permission_set_rule.invalid_field_name') }
    }, allow_blank: true

    validate :validate_field_name_segments, if: :field_name_changed?
    validate :validate_field_accessor_path, if: :path_check_due?
    validate :validate_field_name_column, if: :column_check_due?
    validate :validate_field_value_text, if: -> { new_record? || will_save_change_to_field_value? }
    validate :validate_field_value_for_operator

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # A copy (Services::Clonable) names what its original names. A rule
    # written before its column was checked is copied as it is: it matches
    # nothing, as the original does — leaving it out would widen the copy's
    # access, refusing it would fail the clone. `rake permission_forge:audit`
    # reports both.
    def initialize_dup(other)
      super
      @copied_column = column_parts
    end

    private

    # What the rule names a column by: the name, its path, the join type (nil,
    # blank and 'filter' are one filter: the admin writes nil) and the model
    # of its Resource (a copy onto another set's Resource of the same model
    # names the same column).
    def column_parts
      column_parts_of([field_name, field_accessor_path, join_type, resource&.name])
    end

    def column_parts_was
      model_was = resource_id_changed? ? PermissionForge::Resource.unscoped.where(id: resource_id_was).pick(:name) : resource&.name
      column_parts_of([field_name_was, field_accessor_path_was, join_type_was, model_was])
    end

    # [name, path, join type, model name], the join type of a filter as nil.
    def column_parts_of(parts)
      name, path, join, model = parts
      [name, path, self.class.filter_join_type?(join) ? nil : join, model]
    end

    def operator_check_due?
      new_record? || will_save_change_to_operator?
    end

    def join_type_check_due?
      new_record? || will_save_change_to_join_type?
    end

    # On a new rule and when what it names changes: a row that already names
    # a missing column stays editable in its other attributes (it matches
    # nothing; the audit reports it). A copy onto another model's Resource is checked.
    def column_check_due?
      return false if @copied_column && @copied_column == column_parts

      new_record? || column_parts != column_parts_was
    end

    # A join rule's path is checked on a new rule and when the path, the join
    # type or the model changes; a row that already carries a path that
    # cannot be followed stays editable in its other attributes (it matches
    # nothing; the audit reports it). A filter rule's path is never joined.
    def path_check_due?
      return false unless join_rule?

      parts = column_parts.drop(1)
      return false if @copied_column && @copied_column.drop(1) == parts

      new_record? || parts != column_parts_was.drop(1)
    end

    # A path ActiveRecord cannot join (Operators::RulePath: no such
    # association, an empty segment, or one no join can be built through —
    # the message names the cause: polymorphic, a record-dependent scope, a
    # broken :through / inverse_of, a class that cannot be loaded) would make
    # the rule match nothing — the join raises. Skipped when the model
    # cannot be loaded.
    def validate_field_accessor_path
      problem = PermissionForge::Operators::RuleProblem.of_path(self)
      return unless problem

      errors.add(:field_accessor_path, problem.validation_message)
    end

    # A name the model's table does not have (along the rule's path), or one
    # qualified with a table that is not there on a rule that joins nothing,
    # would make the rule match nothing — the database rejects the
    # comparison. Only checked when the column can be told
    # (Operators::RuleColumn.for_rule): a model that cannot be loaded now, a
    # name qualified with a real table that is none of the rule's (the query
    # may join it), or an alias a rule's own joins may give, is left to the query.
    def validate_field_name_column
      return if field_name.blank? || errors[:field_name].any?

      problem = column_problem
      errors.add(:field_name, problem.validation_message) if problem
    end

    # The rule's column problem (Operators::RuleProblem.of_column), after
    # reading the schema again for what it names: the schema cache may
    # predate a column a migration just added, or a table (a running server,
    # an old process in a rolling deploy).
    def column_problem
      problem = PermissionForge::Operators::RuleProblem.of_column(self)
      return unless problem

      PermissionForge::Operators::RuleColumn.reread_schema(problem)
      PermissionForge::Operators::RuleProblem.of_column(self)
    end

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

    # A value with a NUL byte cannot reach SQL as a literal (the statement is
    # read cut short): refused for a new or changed value; a stored one
    # matches nothing (Operators::ValueTyping.unquotable?) and the row stays
    # editable in its other attributes.
    def validate_field_value_text
      return unless PermissionForge::Operators::ValueTyping.unquotable?(field_value)

      errors.add(:field_value, I18n.t('permission_forge.validations.permission_set_rule.nul_byte',
                                      default: 'must not contain a NUL byte'))
    end

    def validate_field_value_for_operator
      result = PermissionForge::Operators::Validations.validate(operator, field_value)
      errors.add(result[:field], result[:message]) if result
    end
  end
end
