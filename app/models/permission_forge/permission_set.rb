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
    include PermissionForge::Concerns::KeepsCopiedValues
    include PermissionForge::Concerns::ValidatesColumnLengths
    include PermissionForge::Concerns::RequiresName # name present, on create or rename
    include PermissionForge::Concerns::ValidatesRequiredColumns
    include PermissionForge::Concerns::HasAuditTrail
    include PermissionForge::Concerns::HasTenantScoping
    include PermissionForge::Concerns::HasPermissionSetUsers
    include PermissionForge::Concerns::PermissionsRegenerator
    include PermissionForge::Concerns::InvalidatesManagedActions
    include PermissionForge::Concerns::RecordsAuditEvents
    include PermissionForge::ActivationConditions

    # Its name is configuration, not personal data: #inspect shows it even
    # when filter_parameters (the GDPR patterns) hide a `name` (InspectionFilters).
    PermissionForge::InspectionFilters.show_configuration_names(self)

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

    # What an admin names it: no default, whatever the column of an install
    # made before 0.15 says ('Untitled Permission Set'), so a set created
    # without a name is refused (GeneratedText).
    attribute :name, default: nil
    validates :name, length: { maximum: 255, too_long: ->(*) { I18n.t('permission_forge.validations.too_long', count: 255) } }
    # Unique within its tenant, ignoring case — what the admin's "New
    # Permission Set" form refuses. Checked for a new row and on a rename
    # only: two sets that share a name from before 0.15 stay valid in their
    # other attributes until one is renamed.
    validate :name_unique_in_tenant, if: -> { name.present? && (new_record? || will_save_change_to_name?) }
    # A group id must name a group (of this tenant): optional, but never dangling.
    validates :permission_set_group,
              presence: { message: ->(*) { I18n.t('permission_forge.validations.permission_set.group_missing') } },
              if: -> { permission_set_group_id.present? && will_save_change_to_permission_set_group_id? }
    # The activation conditions (ActivationConditions), checked for a new
    # row and when the condition changes — a row stored before the check
    # stays editable in its other attributes, and is read as unjudgeable:
    # a granting set never passes on it, a muting set always applies. A
    # copy keeps its original's conditions (KeepsCopiedValues). A condition
    # text of whitespace alone (any Unicode space) is stored as nil — no
    # condition, to Ruby and SQL alike; the IP list is stored with commas
    # between the entries, whatever the request wrote (newlines, spaces, an
    # Array through the API).
    keeps_copied :allowed_ips, :allowed_hours_start, :allowed_hours_end, :requires_session_flag
    validates :allowed_hours_start, :allowed_hours_end,
              numericality: { in: 0..23, allow_nil: true,
                              message: ->(*) { I18n.t('permission_forge.validations.permission_set.hours_range') } },
              unless: -> { copied_unchanged?(:allowed_hours_start, :allowed_hours_end) }
    before_validation :normalize_blank_conditions
    before_validation :normalize_allowed_ips, if: -> { will_save_change_to_allowed_ips? && !copied_unchanged?(:allowed_ips) }
    validate :allowed_ips_are_addresses, if: lambda {
      allowed_ips.present? && !copied_unchanged?(:allowed_ips) && (new_record? || will_save_change_to_allowed_ips?)
    }
    validate :hours_window_is_judgeable, if: -> { hours_window.set? && hours_check_due? }
    # A flag no request can carry (ActivationConditions#session_flag_broken?): for a new or changed flag.
    validate :session_flag_is_judgeable, if: lambda {
      session_flag_broken? && !copied_unchanged?(:requires_session_flag) && (new_record? || will_save_change_to_requires_session_flag?)
    }

    scope :muting, -> { where(is_muting: true) }
    scope :granting, -> { where(is_muting: false) }
    # The order sets merge in when a permission hash is built ("first mask
    # strategy wins" depends on it): the one definition — the cache accessor
    # and Admin::EffectiveAccess both read it.
    scope :in_hash_order, -> { order(:created_at, :id) }
    # Mirrors #conditional?: a text of blanks is no condition (TRIM), one
    # hour of the two is one (it cannot be judged, and must be selected per
    # request to fail closed). The SQL holds only the adapter's quoted
    # column names and fixed literals; `where.not` wraps it in NOT (…),
    # never by interpolation (Brakeman reads that as SQL injection).
    scope :conditional, -> { where(conditions_present_sql) }
    scope :unconditional, -> { where.not(conditions_present_sql) }

    # The sets holding an activation condition nobody can judge
    # (ActivationConditions#conditions_broken?), by id: the one reading the
    # security audit's incomplete_conditions and Home's card both take.
    #
    # @return [Array<PermissionSet>]
    def self.with_broken_conditions
      conditional.order(:id).select(&:conditions_broken?)
    end

    apply_tenant_scoping! # from the configuration, as the class loads (HasTenantScoping)

    # Sets named `name`, ignoring case and surrounding spaces (compared by
    # the database on both sides), so "Sales " and "sales" are one name.
    #
    # @param name [String]
    # @return [ActiveRecord::Relation]
    def self.named(name)
      # Arel nodes, quoted when the query is compiled — no SQL string is
      # interpolated; a fresh table, since `arel_table` keeps the prefix it
      # was first built with (the table name is a method: table_name_prefix).
      folded = ->(node) { Arel::Nodes::NamedFunction.new('LOWER', [Arel::Nodes::NamedFunction.new('TRIM', [node])]) }
      where(folded.call(Arel::Table.new(table_name)[:name]).eq(folded.call(Arel::Nodes.build_quoted(name.to_s))))
    end

    # Whether a set of the current tenant is named `name` (any case).
    #
    # @param name [String]
    # @return [Boolean]
    def self.name_taken?(name)
      named(name).exists?
    end

    # `base`, else "`base` 2", "`base` 3", ... — the first name no set of the
    # current tenant uses.
    #
    # @param base [String]
    # @return [String]
    def self.unique_name(base)
      candidate = base
      suffix = 2
      while name_taken?(candidate)
        candidate = "#{base} #{suffix}"
        suffix += 1
      end
      candidate
    end

    # The default name of a copy of the set named `name`: "`name` (copy)",
    # numbered when taken.
    #
    # @param name [String]
    # @return [String]
    def self.copy_name(name)
      unique_name(I18n.t('permission_forge.permission_sets.copy_name', name: name))
    end

    # The SQL of "this row has an activation condition" (.conditional,
    # .unconditional, the RLS policy's view_all bypass), the way
    # #conditional? reads the row.
    #
    # @param table [String, nil] the alias the row is read through (SQL as
    #   written, e.g. `ps`); the quoted table name when nil
    # @return [String]
    def self.conditions_present_sql(table: nil)
      # The pool's connection, never `connection` (it raises under
      # ActiveRecord.permanent_connection_checkout = :disallowed).
      connection_pool.with_connection do |connection|
        qualifier = table || connection.quote_table_name(table_name)
        quoted = ->(column) { "#{qualifier}.#{connection.quote_column_name(column)}" }
        text_present = ->(column) { "COALESCE(TRIM(#{without_blank_lines_sql(quoted.call(column), connection)}), '') <> ''" }
        "(#{text_present.call('requires_session_flag')} OR #{text_present.call('allowed_ips')} " \
          "OR #{quoted.call('allowed_hours_start')} IS NOT NULL OR #{quoted.call('allowed_hours_end')} IS NOT NULL)"
      end
    end

    # A text of blanks is no condition, to SQL as to #conditional? (blank?):
    # TRIM takes the spaces, these REPLACEs the newlines and tabs a textarea leaves.
    def self.without_blank_lines_sql(column_sql, connection)
      ["\n", "\r", "\t"].reduce(column_sql) { |sql, char| "REPLACE(#{sql}, #{connection.quote(char)}, '')" }
    end
    private_class_method :without_blank_lines_sql

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

    # Whether the set has an activation condition: a session flag, an IP
    # list, or any hour of the window (one hour of the two counts: such a
    # window cannot be judged, so the set must be selected per request).
    #
    # @return [Boolean]
    def conditional?
      requires_session_flag.present? || allowed_ips.present? || hours_window.set?
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

    def normalize_allowed_ips
      self.allowed_ips = allowed_ip_list.join(',').presence
    end

    def allowed_ips_are_addresses
      invalid_ip_entries.each do |entry|
        errors.add(:allowed_ips, :invalid_ip_entry,
                   message: I18n.t('permission_forge.validations.permission_set.invalid_ip_entry', entry: entry))
      end
    end

    def hours_changed?
      will_save_change_to_allowed_hours_start? || will_save_change_to_allowed_hours_end?
    end

    # For a new row and when an hour changes; a copy keeps its original's.
    def hours_check_due?
      !copied_unchanged?(:allowed_hours_start, :allowed_hours_end) && (new_record? || hours_changed?)
    end

    # ActivationConditions.condition_text: whitespace alone is no condition.
    def normalize_blank_conditions
      %i[requires_session_flag allowed_ips].each do |attribute|
        next unless will_save_change_to_attribute?(attribute) && !copied_unchanged?(attribute)

        self[attribute] = PermissionForge::ActivationConditions.condition_text(self[attribute])
      end
    end

    def session_flag_is_judgeable
      errors.add(:requires_session_flag, :flag_unusable, message: I18n.t('permission_forge.validations.permission_set.flag_unusable'))
    end

    # The error goes on the hour that is missing, or on the end hour that
    # repeats the start; an hour outside 0..23 is the numericality's.
    def hours_window_is_judgeable
      case hours_window.problem
      when :hours_incomplete
        errors.add(allowed_hours_start.nil? ? :allowed_hours_start : :allowed_hours_end, :hours_incomplete,
                   message: I18n.t('permission_forge.validations.permission_set.hours_incomplete'))
      when :hours_equal
        errors.add(:allowed_hours_end, :hours_equal, message: I18n.t('permission_forge.validations.permission_set.hours_equal'))
      end
    end

    def name_unique_in_tenant
      return unless same_name_in_tenant.exists?

      errors.add(:name, :taken, message: I18n.t('permission_forge.validations.permission_set.name_taken'))
    end

    # The other sets of this record's tenant (not the ambient one) with its
    # name. Without tenancy (or on a table with no tenant column): every set.
    def same_name_in_tenant
      scope = self.class.unscoped.named(name)
      scope = scope.where.not(id: id) if persisted?
      column = uniqueness_tenant_column
      column ? scope.where(column => self[column]) : scope
    end

    def uniqueness_tenant_column
      configuration = PermissionForge.configuration
      return unless configuration.tenant_enabled? && self.class.tenant_scoping_applied?

      column = configuration.resolved_tenant_column.to_s
      column if PermissionForge::SchemaRead.column?(self.class, column, ignored: false)
    end

    # InvalidatesManagedActions: a new set has no resources yet and the index
    # holds no set names, so only switching a set on or off changes what is
    # managed. (Its resources drop the index themselves when they are added
    # or destroyed.)
    def managed_actions_changed?
      !previously_new_record? && saved_change_to_is_active?
    end
  end
end
